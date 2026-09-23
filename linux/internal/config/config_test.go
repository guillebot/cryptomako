package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveLocalRequiresPasswordEnv(t *testing.T) {
	t.Setenv(EnvPassword, "")
	_, err := Resolve(Request{LocalPath: "/tmp/vault"})
	if err == nil {
		t.Fatal("expected missing password error")
	}
}

func TestResolveLocal(t *testing.T) {
	t.Setenv(EnvPassword, "test-pass")
	dir := t.TempDir()
	cfg, err := Resolve(Request{LocalPath: dir})
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.IsLocal() {
		t.Fatal("expected local config")
	}
	if cfg.Passphrase != "test-pass" {
		t.Fatalf("passphrase = %q", cfg.Passphrase)
	}
	if cfg.SecretKey != "" {
		t.Fatal("local unlock must not require secret key")
	}
	if !cfg.PathStyle {
		t.Fatal("pathStyle must default true")
	}
}

func TestResolveRemoteHTTPSAndSecrets(t *testing.T) {
	t.Setenv(EnvPassword, "pw")
	t.Setenv(EnvSecretKey, "sk")
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	// macOS docs/10-m0-fixture.md field name: accessKey
	if err := os.WriteFile(path, []byte(`{"endpoint":"https://minio.example","region":"us-east-1","bucket":"b","prefix":"v","accessKey":"ak","pathStyle":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Resolve(Request{ConfigPath: path})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Endpoint != "https://minio.example" || cfg.Bucket != "b" || cfg.Prefix != "v/" || cfg.AccessKey != "ak" {
		t.Fatalf("unexpected cfg: %+v", cfg)
	}
	if cfg.SecretKey != "sk" {
		t.Fatal("secret key not loaded from env")
	}
	if !cfg.PathStyle {
		t.Fatal("pathStyle must be true")
	}
}

func TestResolveAccessKeyIdLegacyAlias(t *testing.T) {
	t.Setenv(EnvPassword, "pw")
	t.Setenv(EnvSecretKey, "sk")
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"endpoint":"https://minio.example","bucket":"b","accessKeyId":"legacy-ak"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Resolve(Request{ConfigPath: path})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AccessKey != "legacy-ak" {
		t.Fatalf("accessKey = %q", cfg.AccessKey)
	}
}

func TestRejectPathStyleFalse(t *testing.T) {
	t.Setenv(EnvPassword, "pw")
	t.Setenv(EnvSecretKey, "sk")
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"endpoint":"https://minio.example","bucket":"b","accessKey":"ak","pathStyle":false}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Resolve(Request{ConfigPath: path})
	if err == nil {
		t.Fatal("expected pathStyle=false rejection")
	}
}

func TestRejectHTTPEndpoint(t *testing.T) {
	t.Setenv(EnvPassword, "pw")
	t.Setenv(EnvSecretKey, "sk")
	_, err := Resolve(Request{
		Endpoint:  "http://minio.example",
		Bucket:    "b",
		AccessKey: "ak",
	})
	if err == nil {
		t.Fatal("expected HTTPS enforcement")
	}
}

func TestRejectSecretsInJSON(t *testing.T) {
	t.Setenv(EnvPassword, "pw")
	t.Setenv(EnvSecretKey, "sk")
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"endpoint":"https://x","bucket":"b","accessKey":"ak","password":"nope"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Resolve(Request{ConfigPath: path})
	if err == nil {
		t.Fatal("expected reject secrets in JSON")
	}
}

func TestDefaultConfigPathUsesXDG(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/xdg-test")
	got := DefaultConfigPath()
	want := "/tmp/xdg-test/cryptomako/config.json"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
