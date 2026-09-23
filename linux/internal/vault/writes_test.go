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

func TestCreateFormat8RoundTrip(t *testing.T) {
	root := t.TempDir()
	pass := "create-format8-pass"
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.Format != Format8 || s.CipherCombo != "SIV_GCM" {
		t.Fatalf("format=%d combo=%s", s.Format, s.CipherCombo)
	}
	payload := []byte("created\n")
	if err := s.PutFile("/hi.txt", payload); err != nil {
		t.Fatal(err)
	}
	r, err := s.Open("/hi.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	r.Close()
	if string(got) != string(payload) {
		t.Fatalf("%q", got)
	}
}

func TestDeleteRenameFailClosedMemStore(t *testing.T) {
	pass := "mem-fail-pass"
	// Build vault on disk then copy keys into memStore via CreateFormat8 + re-wrap.
	disk := t.TempDir()
	s, err := CreateFormat8(disk, pass)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutFile("/a.txt", []byte("a")); err != nil {
		t.Fatal(err)
	}
	s.Close()

	// Re-unlock with memStore seeded from disk for fail injection.
	store := newMemStore()
	if err := seedMemFromDisk(store, disk); err != nil {
		t.Fatal(err)
	}
	s2, err := unlockWithStore(config.Config{Passphrase: pass}, store)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	store.failPut = true
	if err := s2.PutFile("/b.txt", []byte("b")); err == nil {
		t.Fatal("expected put failure")
	}
	store.failPut = false
	if err := s2.PutFile("/b.txt", []byte("b")); err != nil {
		t.Fatal(err)
	}
	store.failDelete = true
	if err := s2.DeleteFile("/b.txt"); err == nil {
		t.Fatal("expected delete failure")
	}
	store.failDelete = false
	if err := s2.Rename("/a.txt", "/c.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := s2.Open("/c.txt"); err != nil {
		t.Fatal(err)
	}
	if err := s2.DeleteFile("/c.txt"); err != nil {
		t.Fatal(err)
	}
}

func seedMemFromDisk(m *memStore, root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		key := filepath.ToSlash(rel)
		return m.Put(key, data)
	})
}
