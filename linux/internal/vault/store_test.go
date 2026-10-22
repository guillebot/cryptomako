package vault

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalStoreRejectsDotDot(t *testing.T) {
	root := t.TempDir()
	s, err := newLocalStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.resolve("../outside"); err == nil {
		t.Fatal("expected .. rejection")
	}
}

func TestLocalStoreRejectsSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "vault")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "leak.txt"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	s, err := newLocalStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.resolve("escape/leak.txt"); err == nil {
		t.Fatal("expected symlink escape rejection")
	}
	// Nested key inside vault still works.
	if err := s.Put("d/ab/file.c9r", []byte("ok")); err != nil {
		t.Fatal(err)
	}
}
