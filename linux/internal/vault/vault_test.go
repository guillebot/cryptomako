package vault

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
)

func TestUnlockLocalRequiresVaultFile(t *testing.T) {
	dir := t.TempDir()
	_, err := Unlock(config.Config{LocalRoot: dir, Passphrase: "x"})
	if err == nil {
		t.Fatal("expected missing vault.cryptomator")
	}
}

func TestUnlockLocalStubSucceedsWithFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "vault.cryptomator")
	// Opaque JWT-shaped placeholder — we do not claim to decrypt it.
	if err := os.WriteFile(path, []byte("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.stub"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Unlock(config.Config{LocalRoot: dir, Passphrase: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if s.Format != Format8 {
		t.Fatalf("format = %d", s.Format)
	}
	_, err = s.List("/", false)
	if err == nil || !strings.Contains(err.Error(), "stubbed") {
		t.Fatalf("List should be stubbed, got %v", err)
	}
	_, err = s.Open("/hello.txt")
	if err == nil || !strings.Contains(err.Error(), "stubbed") {
		t.Fatalf("Open should be stubbed, got %v", err)
	}
}

func TestCipherDirPrefix(t *testing.T) {
	got := CipherDirPrefix("vault", "aabbccddee")
	want := "vault/d/aa/bbccddee/"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestUnlockRemoteNotImplemented(t *testing.T) {
	_, err := Unlock(config.Config{
		Endpoint:   "https://minio.example",
		Bucket:     "b",
		Passphrase: "x",
	})
	if err == nil {
		t.Fatal("expected not implemented")
	}
}
