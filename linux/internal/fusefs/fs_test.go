package fusefs

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/guillebot/cryptomako/linux/internal/config"
	"github.com/guillebot/cryptomako/linux/internal/vault"
	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
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

func unlockTempVault(t *testing.T) *vault.Session {
	t.Helper()
	pass := "fuse-rw-test-password"
	root := t.TempDir()
	s, err := vault.CreateFormat8(root, pass)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := s.PutFile("/hello.txt", []byte("hello cryptomako\n")); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestNewCleartextRootReaddir(t *testing.T) {
	s := unlockFixture(t)
	defer s.Close()

	embed := NewCleartextRoot(s, false)
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
		"bin":             true,
		"café résumé.txt": true,
		"hello.txt":       true,
		"notes":           true,
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

func TestFUSECleartextOpenPath(t *testing.T) {
	s := unlockFixture(t)
	defer s.Close()
	_ = NewCleartextRoot(s, false)

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

func TestFUSEReadOnlyRejectsCreate(t *testing.T) {
	s := unlockTempVault(t)
	defer s.Close()
	root := NewCleartextRoot(s, false).(*dirNode)
	var out fuse.EntryOut
	_, _, _, errno := root.Create(context.Background(), "x.txt", syscall.O_CREAT|syscall.O_WRONLY, 0644, &out)
	if errno != syscall.EROFS {
		t.Fatalf("want EROFS got %v", errno)
	}
}

// TestFUSEWritableWriteFlushRoundTrip exercises NodeWriter/Flusher without a live
// mount (openFile + PutFile fail-closed commit).
func TestFUSEWritableWriteFlushRoundTrip(t *testing.T) {
	s := unlockTempVault(t)
	defer s.Close()
	if err := s.PutFile("/note.txt", nil); err != nil {
		t.Fatal(err)
	}
	fn := &fileNode{session: s, clearPath: "/note.txt", rw: true, loaded: true}
	fh := &openFile{node: fn, data: nil, dirty: false}
	ctx := context.Background()
	payload := []byte("writable-fuse-payload\n")
	n, errno := fn.Write(ctx, fh, payload, 0)
	if errno != 0 || int(n) != len(payload) {
		t.Fatalf("Write n=%d errno=%v", n, errno)
	}
	if errno := fn.Flush(ctx, fh); errno != 0 {
		t.Fatalf("Flush: %v", errno)
	}
	r, err := s.Open("/note.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	r.Close()
	if string(got) != string(payload) {
		t.Fatalf("got %q", got)
	}
}

func TestFUSEWritableUnlinkRename(t *testing.T) {
	s := unlockTempVault(t)
	defer s.Close()
	if err := s.PutFile("/a.txt", []byte("a")); err != nil {
		t.Fatal(err)
	}
	root := NewCleartextRoot(s, true).(*dirNode)
	ctx := context.Background()
	if errno := root.Rename(ctx, "a.txt", root, "b.txt", 0); errno != 0 {
		t.Fatalf("Rename: %v", errno)
	}
	if _, err := s.Open("/b.txt"); err != nil {
		t.Fatalf("after rename: %v", err)
	}
	if errno := root.Unlink(ctx, "b.txt"); errno != 0 {
		t.Fatalf("Unlink: %v", errno)
	}
	if _, err := s.Open("/b.txt"); err == nil {
		t.Fatal("expected missing after unlink")
	}
}

func TestFUSEWritableFailClosedOnPut(t *testing.T) {
	pass := "fail-closed-pass"
	rootDir := t.TempDir()
	s, err := vault.CreateFormat8(rootDir, pass)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()

	chmodTree(t, rootDir, 0555)
	t.Cleanup(func() { chmodTree(t, rootDir, 0755) })

	s2, err := vault.Unlock(config.Config{LocalRoot: rootDir, Passphrase: pass})
	if err != nil {
		t.Fatalf("re-unlock: %v", err)
	}
	defer s2.Close()

	root := NewCleartextRoot(s2, true).(*dirNode)
	var out fuse.EntryOut
	_, _, _, errno := root.Create(context.Background(), "nope.txt", syscall.O_CREAT|syscall.O_WRONLY, 0644, &out)
	if errno != syscall.EIO {
		t.Fatalf("want EIO on failed put, got %v", errno)
	}
}

func TestFUSEWritableFailClosedOnFlush(t *testing.T) {
	pass := "fail-closed-flush"
	rootDir := t.TempDir()
	s, err := vault.CreateFormat8(rootDir, pass)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.PutFile("/x.txt", []byte("old")); err != nil {
		t.Fatal(err)
	}
	s.Close()

	chmodTree(t, rootDir, 0555)
	t.Cleanup(func() { chmodTree(t, rootDir, 0755) })

	s2, err := vault.Unlock(config.Config{LocalRoot: rootDir, Passphrase: pass})
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	fn := &fileNode{session: s2, clearPath: "/x.txt", rw: true, loaded: true, data: []byte("old")}
	fh := &openFile{node: fn, data: []byte("new-data"), dirty: true}
	if errno := fn.Flush(context.Background(), fh); errno != syscall.EIO {
		t.Fatalf("want EIO got %v", errno)
	}
}

func chmodTree(t *testing.T, root string, mode os.FileMode) {
	t.Helper()
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		_ = os.Chmod(path, mode)
		return nil
	})
}
