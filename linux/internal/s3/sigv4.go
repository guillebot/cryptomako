package s3

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// EmptyPayloadSHA256 is SHA256 of the empty string (unsigned GET/DELETE bodies).
const EmptyPayloadSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// Credentials for AWS Signature Version 4 (S3).
type Credentials struct {
	AccessKey string
	SecretKey string
	Region    string
	Service   string // default "s3"
}

func (c Credentials) service() string {
	if c.Service == "" {
		return "s3"
	}
	return c.Service
}

// SignRequest adds SigV4 Authorization and related headers to req.
// payloadHash is the hex SHA256 of the body (or EmptyPayloadSHA256 / UNSIGNED-PAYLOAD).
func SignRequest(req *http.Request, creds Credentials, payloadHash string, now time.Time) error {
	if payloadHash == "" {
		payloadHash = EmptyPayloadSHA256
	}
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	amzDate := now.Format("20060102T150405Z")
	dateStamp := amzDate[:8]

	hostHeader := req.URL.Host
	if hostHeader == "" {
		hostHeader = req.Host
	}
	req.Header.Set("Host", hostHeader)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)

	canonicalURI := CanonicalPath(req.URL)
	canonicalQuery := CanonicalQueryString(req.URL)

	// Headers we sign: host, x-amz-content-sha256, x-amz-date (lowercase).
	headers := map[string]string{
		"host":                 hostHeader,
		"x-amz-content-sha256": payloadHash,
		"x-amz-date":           amzDate,
	}
	keys := make([]string, 0, len(headers))
	for k := range headers {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var canonicalHeaders strings.Builder
	for _, k := range keys {
		canonicalHeaders.WriteString(k)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(strings.TrimSpace(headers[k]))
		canonicalHeaders.WriteByte('\n')
	}
	signedHeaders := strings.Join(keys, ";")

	method := req.Method
	if method == "" {
		method = http.MethodGet
	}
	canonicalRequest := strings.Join([]string{
		method,
		canonicalURI,
		canonicalQuery,
		canonicalHeaders.String(),
		signedHeaders,
		payloadHash,
	}, "\n")

	scope := fmt.Sprintf("%s/%s/%s/aws4_request", dateStamp, creds.Region, creds.service())
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		hexSHA256([]byte(canonicalRequest)),
	}, "\n")

	signingKey := deriveKey(creds.SecretKey, dateStamp, creds.Region, creds.service())
	signature := hex.EncodeToString(hmacSHA256(signingKey, []byte(stringToSign)))
	for i := range signingKey {
		signingKey[i] = 0
	}

	auth := fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		creds.AccessKey, scope, signedHeaders, signature,
	)
	req.Header.Set("Authorization", auth)
	return nil
}

// CanonicalPath encodes the path for SigV4: segments percent-encoded, "/" preserved.
// Uses EscapedPath (not Path) so a trailing slash on ListObjectsV2 is kept.
func CanonicalPath(u *url.URL) string {
	raw := u.EscapedPath()
	if raw == "" {
		raw = "/"
	}
	decoded, err := url.PathUnescape(raw)
	if err != nil {
		decoded = raw
	}
	if decoded == "" {
		decoded = "/"
	}
	return URIEncode(decoded, false)
}

// CanonicalQueryString builds the sorted, URI-encoded query (slash → %2F).
func CanonicalQueryString(u *url.URL) string {
	return CanonicalQueryFromValues(u.Query())
}

// CanonicalQueryFromValues is the testable form of query canonicalization.
func CanonicalQueryFromValues(q url.Values) string {
	if len(q) == 0 {
		return ""
	}
	type pair struct{ name, value string }
	var pairs []pair
	for name, values := range q {
		encName := URIEncode(name, true)
		if len(values) == 0 {
			pairs = append(pairs, pair{encName, ""})
			continue
		}
		for _, v := range values {
			pairs = append(pairs, pair{encName, URIEncode(v, true)})
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].name == pairs[j].name {
			return pairs[i].value < pairs[j].value
		}
		return pairs[i].name < pairs[j].name
	})
	parts := make([]string, len(pairs))
	for i, p := range pairs {
		parts[i] = p.name + "=" + p.value
	}
	return strings.Join(parts, "&")
}

// URIEncode percent-encodes per AWS SigV4 (RFC 3986 unreserved left alone).
func URIEncode(s string, encodeSlash bool) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~':
			b.WriteByte(c)
		case c == '/':
			if encodeSlash {
				b.WriteString("%2F")
			} else {
				b.WriteByte('/')
			}
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func deriveKey(secret, dateStamp, region, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), []byte(dateStamp))
	kRegion := hmacSHA256(kDate, []byte(region))
	kService := hmacSHA256(kRegion, []byte(service))
	return hmacSHA256(kService, []byte("aws4_request"))
}

func hmacSHA256(key, data []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(data)
	return m.Sum(nil)
}

func hexSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// PayloadSHA256 returns the hex SHA256 of data.
func PayloadSHA256(data []byte) string {
	return hexSHA256(data)
}
