// Package config loads non-secret CryptoMako settings from XDG config.
//
// Password and S3 secret key must come from environment variables only —
// never from argv and never from JSON.
package config

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

const (
	EnvPassword  = "CRYPTOMAKO_PASSWORD"
	EnvSecretKey = "CRYPTOMAKO_SECRET_KEY"
)

// File is the on-disk JSON shape (no secrets).
// Field names align with macOS VaultSettings / PocConfig / docs/10-m0-fixture.md.
// accessKeyId is accepted as a legacy Linux alias for accessKey.
type File struct {
	Endpoint    string `json:"endpoint,omitempty"`
	Region      string `json:"region,omitempty"`
	Bucket      string `json:"bucket,omitempty"`
	Prefix      string `json:"prefix,omitempty"`
	AccessKey   string `json:"accessKey,omitempty"`
	AccessKeyID string `json:"accessKeyId,omitempty"` // legacy alias
	// PathStyle defaults true (Platforms lock for MinIO/R2). Virtual-hosted is unsupported.
	PathStyle *bool `json:"pathStyle,omitempty"`
}

// Request is CLI / flag input merged over the config file.
type Request struct {
	LocalPath    string
	ConfigPath   string
	Endpoint     string
	Region       string
	Bucket       string
	Prefix       string
	AccessKey    string
	PasswordEnv  string
	SecretKeyEnv string
}

// Config is the fully resolved connection (secrets included from env).
type Config struct {
	Endpoint   string // HTTPS S3 API URL, or empty when LocalRoot is set
	Region     string
	Bucket     string
	Prefix     string
	AccessKey  string
	SecretKey  string
	Passphrase string
	PathStyle  bool
	LocalRoot  string // absolute vault directory when using --local
}

// IsLocal reports whether this config unlocks a directory on disk.
func (c Config) IsLocal() bool { return c.LocalRoot != "" }

// DefaultConfigPath returns ~/.config/cryptomako/config.json (XDG).
func DefaultConfigPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "cryptomako", "config.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "cryptomako", "config.json")
	}
	return filepath.Join(home, ".config", "cryptomako", "config.json")
}

// Resolve merges flags, config file, and env into a Config.
// On success, secret env vars named by the request are unset in this process
// so they no longer appear in /proc/self/environ (FUSE mounts stay long-lived).
func Resolve(req Request) (Config, error) {
	if req.PasswordEnv == "" {
		req.PasswordEnv = EnvPassword
	}
	if req.SecretKeyEnv == "" {
		req.SecretKeyEnv = EnvSecretKey
	}

	passphrase := os.Getenv(req.PasswordEnv)
	if passphrase == "" {
		return Config{}, fmt.Errorf("missing env %s", req.PasswordEnv)
	}

	if local := strings.TrimSpace(req.LocalPath); local != "" {
		abs, err := filepath.Abs(local)
		if err != nil {
			return Config{}, err
		}
		scrubSecretEnvs(req.PasswordEnv, req.SecretKeyEnv)
		return Config{
			Region:     "local",
			Bucket:     "local",
			AccessKey:  "local",
			Passphrase: passphrase,
			PathStyle:  true,
			LocalRoot:  abs,
		}, nil
	}

	filePath := req.ConfigPath
	if filePath == "" {
		filePath = DefaultConfigPath()
	}
	file, err := loadFile(filePath)
	if err != nil {
		return Config{}, err
	}

	endpoint := firstNonEmpty(req.Endpoint, file.Endpoint)
	region := firstNonEmpty(req.Region, file.Region, "us-east-1")
	bucket := firstNonEmpty(req.Bucket, file.Bucket)
	prefix := firstNonEmpty(req.Prefix, file.Prefix)
	accessKey := firstNonEmpty(req.AccessKey, file.AccessKey, file.AccessKeyID)

	pathStyle := true
	if file.PathStyle != nil {
		pathStyle = *file.PathStyle
	}
	if !pathStyle {
		return Config{}, fmt.Errorf("pathStyle=false (virtual-hosted) is not supported; CryptoMako Linux uses path-style S3 (default true)")
	}

	if endpoint == "" {
		return Config{}, fmt.Errorf("missing --endpoint")
	}
	if !strings.HasPrefix(strings.ToLower(endpoint), "https://") {
		return Config{}, fmt.Errorf("endpoint must be HTTPS (got %q)", endpoint)
	}
	if err := rejectEndpointUserinfo(endpoint); err != nil {
		return Config{}, err
	}
	if bucket == "" {
		return Config{}, fmt.Errorf("missing --bucket")
	}
	if accessKey == "" {
		return Config{}, fmt.Errorf("missing --access-key")
	}
	secretKey := os.Getenv(req.SecretKeyEnv)
	if secretKey == "" {
		return Config{}, fmt.Errorf("missing env %s", req.SecretKeyEnv)
	}

	scrubSecretEnvs(req.PasswordEnv, req.SecretKeyEnv)

	return Config{
		Endpoint:   strings.TrimRight(endpoint, "/"),
		Region:     region,
		Bucket:     bucket,
		Prefix:     normalizePrefix(prefix),
		AccessKey:  accessKey,
		SecretKey:  secretKey,
		Passphrase: passphrase,
		PathStyle:  true,
	}, nil
}

func loadFile(path string) (File, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return File{}, nil
		}
		return File{}, err
	}
	var f File
	if err := json.Unmarshal(data, &f); err != nil {
		return File{}, fmt.Errorf("config %s: %w", path, err)
	}
	// Reject accidental secrets in JSON.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err == nil {
		for _, banned := range bannedSecretJSONKeys {
			if _, ok := raw[banned]; ok {
				return File{}, fmt.Errorf("config %s must not contain %q (use env)", path, banned)
			}
		}
	}
	return f, nil
}

func normalizePrefix(p string) string {
	p = strings.TrimSpace(p)
	if p == "" {
		return ""
	}
	p = strings.Trim(p, "/")
	if p == "" {
		return ""
	}
	return p + "/"
}

// bannedSecretJSONKeys must never appear in on-disk JSON configs.
var bannedSecretJSONKeys = []string{
	"password", "passphrase", "secretKey", "secret_key", "secretAccessKey",
	"aws_secret_access_key", "secret", "proxyPassword", "proxy_password",
}

// scrubSecretEnvs removes secret values from this process environment.
func scrubSecretEnvs(names ...string) {
	for _, name := range names {
		if name == "" {
			continue
		}
		_ = os.Unsetenv(name)
	}
}

// ScrubProxyPasswordEnv unsets CRYPTOMAKO_PROXY_PASSWORD after it has been
// copied into the HTTP transport (see NewHTTPClient).
func ScrubProxyPasswordEnv() {
	_ = os.Unsetenv(EnvProxyPassword)
}

// ClearSecrets blanks secret fields on Config (does not zero underlying string
// bytes — Go strings are immutable; prefer scrubSecretEnvs for /proc exposure).
func (c *Config) ClearSecrets() {
	if c == nil {
		return
	}
	c.Passphrase = ""
	c.SecretKey = ""
}

func rejectEndpointUserinfo(endpoint string) error {
	// Avoid secrets in URL userinfo (https://key:secret@host) landing in JSON/argv.
	// Parse after scheme check; url.Parse accepts https.
	u, err := url.Parse(endpoint)
	if err != nil {
		return fmt.Errorf("endpoint: %w", err)
	}
	if u.User != nil {
		return fmt.Errorf("endpoint must not include userinfo (credentials belong in env %s)", EnvSecretKey)
	}
	return nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
