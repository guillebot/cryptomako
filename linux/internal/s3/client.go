// Package s3 is a minimal SigV4 HTTPS client for S3-compatible APIs.
//
// No AWS SDK: requests are signed in-process and sent with net/http.
// Product lock: HTTPS only; remote put/delete fail closed on non-2xx.
package s3

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Settings for an S3-compatible endpoint (path-style by default).
type Settings struct {
	Endpoint  string // e.g. https://minio.example:9000
	Region    string
	Bucket    string
	AccessKey string
	SecretKey string
	PathStyle bool // true for MinIO / custom endpoints (CryptoMako default)
}

// Client talks to S3 over HTTPS with hand-rolled SigV4.
type Client struct {
	settings Settings
	http     *http.Client
}

// New builds a path-style HTTPS client. Endpoint must be https://.
func New(settings Settings) (*Client, error) {
	if settings.Endpoint == "" {
		return nil, fmt.Errorf("s3: empty endpoint")
	}
	if !strings.HasPrefix(strings.ToLower(settings.Endpoint), "https://") {
		return nil, fmt.Errorf("s3: HTTPS required (got %q)", settings.Endpoint)
	}
	if settings.Bucket == "" {
		return nil, fmt.Errorf("s3: empty bucket")
	}
	settings.PathStyle = true
	return &Client{
		settings: settings,
		http: &http.Client{
			Timeout: 10 * time.Minute,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

// Object is a listed S3 object.
type Object struct {
	Key  string
	Size int64
	ETag string
}

// ListResult is a ListObjectsV2 page.
type ListResult struct {
	Objects               []Object
	CommonPrefixes        []string
	IsTruncated           bool
	NextContinuationToken string
}

// GetObject downloads an object body.
func (c *Client) GetObject(ctx context.Context, key string) ([]byte, error) {
	req, err := c.newRequest(ctx, http.MethodGet, key, nil, nil)
	if err != nil {
		return nil, err
	}
	if err := SignRequest(req, c.creds(), EmptyPayloadSHA256, time.Time{}); err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("s3 get %s: %w", key, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if err := checkStatus(resp, key, body); err != nil {
		return nil, err
	}
	return body, nil
}

// HeadObject reports whether an object exists (HTTP 200). 404 → false, nil.
func (c *Client) HeadObject(ctx context.Context, key string) (bool, error) {
	req, err := c.newRequest(ctx, http.MethodHead, key, nil, nil)
	if err != nil {
		return false, err
	}
	if err := SignRequest(req, c.creds(), EmptyPayloadSHA256, time.Time{}); err != nil {
		return false, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return false, fmt.Errorf("s3 head %s: %w", key, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return false, nil
	}
	body, _ := io.ReadAll(resp.Body)
	if err := checkStatus(resp, key, body); err != nil {
		return false, err
	}
	return true, nil
}

// PutObject uploads data. Fail-closed: only 2xx is success.
func (c *Client) PutObject(ctx context.Context, key string, data []byte) error {
	hash := PayloadSHA256(data)
	req, err := c.newRequest(ctx, http.MethodPut, key, nil, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.ContentLength = int64(len(data))
	req.Header.Set("Content-Length", fmt.Sprintf("%d", len(data)))
	if err := SignRequest(req, c.creds(), hash, time.Time{}); err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("s3 put %s: %w", key, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return checkStatus(resp, key, body)
}

// DeleteObject removes an object. Fail-closed: only 2xx is success.
func (c *Client) DeleteObject(ctx context.Context, key string) error {
	req, err := c.newRequest(ctx, http.MethodDelete, key, nil, nil)
	if err != nil {
		return err
	}
	if err := SignRequest(req, c.creds(), EmptyPayloadSHA256, time.Time{}); err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("s3 delete %s: %w", key, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return checkStatus(resp, key, body)
}

// ListObjectsV2 lists objects under prefix (optional delimiter).
func (c *Client) ListObjectsV2(ctx context.Context, prefix, delimiter, continuationToken string) (ListResult, error) {
	q := url.Values{}
	q.Set("list-type", "2")
	q.Set("max-keys", "1000")
	if prefix != "" {
		q.Set("prefix", prefix)
	}
	if delimiter != "" {
		q.Set("delimiter", delimiter)
	}
	if continuationToken != "" {
		q.Set("continuation-token", continuationToken)
	}
	req, err := c.newRequest(ctx, http.MethodGet, "", q, nil)
	if err != nil {
		return ListResult{}, err
	}
	if err := SignRequest(req, c.creds(), EmptyPayloadSHA256, time.Time{}); err != nil {
		return ListResult{}, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return ListResult{}, fmt.Errorf("s3 list: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return ListResult{}, err
	}
	if err := checkStatus(resp, prefix, body); err != nil {
		return ListResult{}, err
	}
	return ParseListObjectsV2(body)
}

// SetHTTPClient replaces the underlying HTTP client (tests / custom TLS).
func (c *Client) SetHTTPClient(h *http.Client) {
	if h != nil {
		c.http = h
	}
}

func (c *Client) creds() Credentials {
	return Credentials{
		AccessKey: c.settings.AccessKey,
		SecretKey: c.settings.SecretKey,
		Region:    c.settings.Region,
	}
}

func (c *Client) newRequest(ctx context.Context, method, key string, query url.Values, body io.Reader) (*http.Request, error) {
	u, err := url.Parse(c.settings.Endpoint)
	if err != nil {
		return nil, err
	}
	// Path-style: https://endpoint/bucket/key — trailing slash kept for bucket-level list.
	path := "/" + c.settings.Bucket
	key = strings.TrimPrefix(key, "/")
	if key != "" {
		path += "/" + key
	} else if query != nil {
		path += "/"
	}
	u.Path = path
	u.RawPath = ""
	if query != nil {
		// Wire query must match SigV4 canonical form (slash → %2F).
		u.RawQuery = CanonicalQueryFromValues(query)
	}
	return http.NewRequestWithContext(ctx, method, u.String(), body)
}

func checkStatus(resp *http.Response, key string, body []byte) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	msg := strings.TrimSpace(string(body))
	if len(msg) > 512 {
		msg = msg[:512] + "…"
	}
	return fmt.Errorf("s3 %s %s: HTTP %d %s", resp.Request.Method, key, resp.StatusCode, msg)
}
