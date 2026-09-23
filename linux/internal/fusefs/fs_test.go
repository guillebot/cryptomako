package fusefs

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/hanwen/go-fuse/v2/fs"
)

func fixturesDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join("..", "..", "..", "fixtures")
	abs, err := filepath.Abs(dir)
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

func fixturePassword(t *testing.T) (string, bool) {
	t.Helper()
	path := filepath.Join(fixturesDir(t), "PASSWORD")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(data)), true
}

func unlockFixture(t *testing.T) *vault.Session {
	t.Helper()
	pass, ok := fixturePassword(t)
	if !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
	rootPath := filepath.Join(fixturesDir(t), "vault")
	s, err := vault.Unlock(config.Config{LocalRoot: rootPath, Passphrase: pass})
	if err != nil {
		t.Fatalf("unlock: %v", err)
	}
	return s
}

// TestNewCleartextRootReaddir constructs the FUSE root without /dev/fuse and
// verifies Readdir returns fixture cleartext basenames (including Unicode + long name).
func TestNewCleartextRootReaddir(t *testing.T) {
	s := unlockFixture(t)
	defer s.Close()

	embed := NewCleartextRoot(s)
	if embed == nil {
		t.Fatal("NewCleartextRoot returned nil")
	}
	if _, ok := embed.(fs.InodeEmbedder); !ok {
		t.Fatal("root is not InodeEmbedder")
	}
	root, ok := embed.(*dirNode)
	if !ok {
		t.Fatalf("root type %T", embed)
	}
	if root.clearPath != "/" {
		t.Fatalf("clearPath=%q", root.clearPath)
	}

	stream, errno := root.Readdir(context.Background())
	if errno != 0 {
		t.Fatalf("Readdir errno=%v", errno)
	}
	var names []string
	for stream.HasNext() {
		de, errn := stream.Next()
		if errn != 0 {
			t.Fatalf("Next errno=%v", errn)
		}
		names = append(names, de.Name)
	}

	wantExact := map[string]bool{
		"bin":              true,
		"café résumé.txt":  true,
		"hello.txt":        true,
		"notes":            true,
	}
	foundLong := false
	for _, n := range names {
		if strings.HasPrefix(n, "nnnn") && strings.HasSuffix(n, ".txt") && len(n) > 100 {
			foundLong = true
			continue
		}
		if !wantExact[n] {
			t.Errorf("unexpected name %q", n)
			continue
		}
		delete(wantExact, n)
	}
	if !foundLong {
		t.Error("missing long .c9s cleartext name")
	}
	for n := range wantExact {
		t.Errorf("missing name %q", n)
	}
}

// TestFUSECleartextOpenPath ensures the cleartext path FUSE file nodes use
// decrypts to the fixture payload (no live mount required).
func TestFUSECleartextOpenPath(t *testing.T) {
	s := unlockFixture(t)
	defer s.Close()
	_ = NewCleartextRoot(s) // construct FS object

	r, err := s.Open("/hello.txt")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer r.Close()
	body, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "hello cryptomako") {
		t.Fatalf("body=%q", body)
	}
}
