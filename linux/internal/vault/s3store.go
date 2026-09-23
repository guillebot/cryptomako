package vault

import (
	"context"
	"strings"

	"github.com/guillebot/cryptomako/linux/internal/s3"
)

// s3Store adapts the SigV4 HTTPS client to objectStore.
// Keys passed to Get/ListImmediate are vault-relative (no bucket prefix).
type s3Store struct {
	client *s3.Client
	prefix string // e.g. "vault/" — slash-normalized or empty
	ctx    context.Context
}

func newS3StoreFrom(client *s3.Client, prefix string) *s3Store {
	prefix = strings.TrimSpace(prefix)
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return &s3Store{
		client: client,
		prefix: prefix,
		ctx:    context.Background(),
	}
}

func (s *s3Store) fullKey(rel string) string {
	rel = strings.TrimPrefix(rel, "/")
	return s.prefix + rel
}

func (s *s3Store) strip(key string) string {
	if s.prefix != "" && strings.HasPrefix(key, s.prefix) {
		return strings.TrimPrefix(key, s.prefix)
	}
	return key
}

func (s *s3Store) Get(key string) ([]byte, error) {
	data, err := s.client.GetObject(s.ctx, s.fullKey(key))
	if err != nil {
		if isNotFound(err) {
			return nil, errNotFound
		}
		return nil, err
	}
	return data, nil
}

func (s *s3Store) Exists(key string) bool {
	ok, err := s.client.HeadObject(s.ctx, s.fullKey(key))
	return err == nil && ok
}

func (s *s3Store) ListImmediate(prefix string) (objects []string, prefixes []string, err error) {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	full := s.fullKey(prefix)
	var token string
	for {
		page, err := s.client.ListObjectsV2(s.ctx, full, "/", token)
		if err != nil {
			return nil, nil, err
		}
		for _, o := range page.Objects {
			rel := s.strip(o.Key)
			if rel == "" || strings.HasSuffix(rel, "/") {
				continue
			}
			// Only immediate children (no extra slash after prefix).
			rest := strings.TrimPrefix(rel, prefix)
			if rest == "" || strings.Contains(rest, "/") {
				continue
			}
			objects = append(objects, rel)
		}
		for _, p := range page.CommonPrefixes {
			rel := s.strip(p)
			if rel == "" {
				continue
			}
			if !strings.HasSuffix(rel, "/") {
				rel += "/"
			}
			prefixes = append(prefixes, rel)
		}
		if !page.IsTruncated || page.NextContinuationToken == "" {
			break
		}
		token = page.NextContinuationToken
	}
	return objects, prefixes, nil
}

func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "HTTP 404") || strings.Contains(msg, "NoSuchKey")
}


func (s *s3Store) Put(key string, data []byte) error {
	// Fail-closed: Client.PutObject only succeeds on HTTP 2xx.
	return s.client.PutObject(s.ctx, s.fullKey(key), data)
}
