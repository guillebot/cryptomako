package vault

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
)

func TestSyncRoundTrip(t *testing.T) {
	pass, ok := fixturePassword(t)
	if !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
	// Copy fixture vault so we do not mutate golden ciphertext.
	srcVault := filepath.Join(fixturesDir(t), "vault")
	dstVault := t.TempDir()
	if err := copyTree(srcVault, dstVault); err != nil {
		t.Fatal(err)
	}

	s, err := Unlock(config.Config{LocalRoot: dstVault, Passphrase: pass})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	clearDir := t.TempDir()
	sub := filepath.Join(clearDir, "subdir")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := []byte("sync-roundtrip-payload\n")
	if err := os.WriteFile(filepath.Join(sub, "note.txt"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	n, err := s.SyncCleartextTree(clearDir, "/")
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("synced %d", n)
	}

	r, err := s.Open("/subdir/note.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	got, _ := io.ReadAll(r)
	if string(got) != string(payload) {
		t.Fatalf("got %q", got)
	}

	// Encrypt/decrypt content unit check
	ct, err := s.cryptor.EncryptContent([]byte("abc"))
	if err != nil {
		t.Fatal(err)
	}
	pt, err := s.cryptor.DecryptContent(ct)
	if err != nil {
		t.Fatal(err)
	}
	if string(pt) != "abc" {
		t.Fatalf("%q", pt)
	}
	_ = strings.Contains
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o600)
	})
}
