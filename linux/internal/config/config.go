// Package config loads non-secret CryptoMako settings from XDG config.
//
// Password and S3 secret key must come from environment variables only —
// never from argv and never from JSON.
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	EnvPassword  = "CRYPTOMAKO_PASSWORD"
	EnvSecretKey = "CRYPTOMAKO_SECRET_KEY"
)

// File is the on-disk JSON shape (no secrets).
type File struct {
	Endpoint    string `json:"endpoint,omitempty"`
	Region      string `json:"region,omitempty"`
	Bucket      string `json:"bucket,omitempty"`
	Prefix      string `json:"prefix,omitempty"`
	AccessKeyID string `json:"accessKeyId,omitempty"`
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
	accessKey := firstNonEmpty(req.AccessKey, file.AccessKeyID)

	if endpoint == "" {
		return Config{}, fmt.Errorf("missing --endpoint")
	}
	if !strings.HasPrefix(strings.ToLower(endpoint), "https://") {
		return Config{}, fmt.Errorf("endpoint must be HTTPS (got %q)", endpoint)
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
		for _, banned := range []string{"password", "secretKey", "secret_key", "secretAccessKey"} {
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

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
