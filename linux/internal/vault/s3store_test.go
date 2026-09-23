package vault

import (
	"crypto/tls"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/s3"
)

// TestS3UnlockListCatFixture spins a TLS path-style fake S3 that serves fixtures/vault.
func TestS3UnlockListCatFixture(t *testing.T) {
	pass, ok := fixturePassword(t)
	if !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
	vaultRoot := filepath.Join(fixturesDir(t), "vault")
	const bucket = "b"
	const prefix = "vault/"

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/")
		// path-style: /bucket/key…
		if !strings.HasPrefix(path, bucket+"/") && path != bucket && path != bucket+"/" {
			http.NotFound(w, r)
			return
		}
		key := strings.TrimPrefix(path, bucket+"/")
		switch r.Method {
		case http.MethodGet:
			if r.URL.RawQuery != "" && strings.Contains(r.URL.RawQuery, "list-type=2") {
				handleFakeList(w, r, vaultRoot, prefix, key)
				return
			}
			serveFixtureObject(w, vaultRoot, prefix, key)
		case http.MethodHead:
			rel := strings.TrimPrefix(key, prefix)
			fp := filepath.Join(vaultRoot, filepath.FromSlash(rel))
			st, err := os.Stat(fp)
			if err != nil || st.IsDir() {
				http.NotFound(w, r)
				return
			}
			w.WriteHeader(http.StatusOK)
		default:
			http.Error(w, "method", http.StatusMethodNotAllowed)
		}
	})

	srv := httptest.NewTLSServer(mux)
	defer srv.Close()

	client, err := s3.New(s3.Settings{
		Endpoint:  srv.URL,
		Region:    "us-east-1",
		Bucket:    bucket,
		AccessKey: "AKIAIOSFODNN7EXAMPLE",
		SecretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
		PathStyle: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	// Trust the test server cert.
	client.SetHTTPClient(&http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // test only
		},
	})

	s, err := unlockWithStore(config.Config{Passphrase: pass}, newS3StoreFrom(client, prefix))
	if err != nil {
		t.Fatalf("unlock: %v", err)
	}
	defer s.Close()
	if s.CipherCombo != "SIV_GCM" || s.Format != Format8 {
		t.Fatalf("meta format=%d combo=%s", s.Format, s.CipherCombo)
	}
	entries, err := s.List("/", true)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var lines []string
	for _, e := range entries {
		name := e.Name
		if e.IsDir {
			name += "/"
		}
		lines = append(lines, name)
	}
	got := strings.Join(lines, "\n") + "\n"
	want, err := os.ReadFile(filepath.Join(fixturesDir(t), "expected-ls.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Fatalf("ls mismatch via S3:\nwant:\n%s\ngot:\n%s", want, got)
	}
	r, err := s.Open("/hello.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	body, _ := io.ReadAll(r)
	if !strings.Contains(string(body), "hello") {
		t.Fatalf("body=%q", body)
	}
}

func serveFixtureObject(w http.ResponseWriter, vaultRoot, prefix, key string) {
	if !strings.HasPrefix(key, prefix) {
		http.NotFound(w, nil)
		return
	}
	rel := strings.TrimPrefix(key, prefix)
	fp := filepath.Join(vaultRoot, filepath.FromSlash(rel))
	data, err := os.ReadFile(fp)
	if err != nil {
		http.NotFound(w, nil)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func handleFakeList(w http.ResponseWriter, r *http.Request, vaultRoot, vaultPrefix, _ string) {
	q := r.URL.Query()
	listPrefix := q.Get("prefix")
	delimiter := q.Get("delimiter")
	rel := strings.TrimPrefix(listPrefix, vaultPrefix)
	dir := filepath.Join(vaultRoot, filepath.FromSlash(rel))
	entries, err := os.ReadDir(dir)
	if err != nil {
		// Empty list
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(`<?xml version="1.0"?><ListBucketResult></ListBucketResult>`))
		return
	}
	var b strings.Builder
	b.WriteString(`<?xml version="1.0"?><ListBucketResult>`)
	for _, e := range entries {
		name := e.Name()
		fullKey := listPrefix + name
		if e.IsDir() {
			if delimiter == "/" {
				b.WriteString("<CommonPrefixes><Prefix>")
				b.WriteString(fullKey + "/")
				b.WriteString("</Prefix></CommonPrefixes>")
			}
			continue
		}
		st, _ := e.Info()
		size := int64(0)
		if st != nil {
			size = st.Size()
		}
		b.WriteString("<Contents><Key>")
		b.WriteString(fullKey)
		b.WriteString("</Key><Size>")
		b.WriteString(itoa(size))
		b.WriteString("</Size><ETag>\"local\"</ETag></Contents>")
	}
	b.WriteString(`</ListBucketResult>`)
	w.Header().Set("Content-Type", "application/xml")
	_, _ = w.Write([]byte(b.String()))
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var d [32]byte
	i := len(d)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		d[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		d[i] = '-'
	}
	return string(d[i:])
}
