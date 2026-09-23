package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvePathReturnsAbs(t *testing.T) {
	dir := t.TempDir()
	got, err := ResolvePath(dir)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.Abs(dir)
	if err != nil {
		t.Fatal(err)
	}
	// Match ResolvePath: prefer EvalSymlinks (macOS /tmp → /private/tmp).
	if resolved, err := filepath.EvalSymlinks(want); err == nil {
		want = resolved
	}
	want = trimPathSep(want)
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestSoftWarnOnAddWhenNestedUnderExisting(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	existing := []BackupSource{NewBackupSource(root, "Root")}
	warn := SoftWarnOnAdd(existing, child)
	if warn == "" {
		t.Fatal("expected soft warn")
	}
	if !strings.Contains(strings.ToLower(warn), "overlap") {
		t.Fatalf("warn=%q", warn)
	}
}

func TestSoftWarnOnAddNullWhenDisjoint(t *testing.T) {
	a := t.TempDir()
	b := t.TempDir()
	existing := []BackupSource{NewBackupSource(a, "A")}
	if warn := SoftWarnOnAdd(existing, b); warn != "" {
		t.Fatalf("expected no warn, got %q", warn)
	}
}

func TestThrowIfOverlappingWhenParentAndChild(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "nested")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	sources := []BackupSource{
		NewBackupSource(root, "Root"),
		NewBackupSource(child, "Child"),
	}
	err := ThrowIfOverlapping(sources)
	if err == nil {
		t.Fatal("expected hard fail")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "refused") {
		t.Fatalf("err=%v", err)
	}
}

func TestThrowIfOverlappingAllowsSiblings(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "b")
	if err := os.Mkdir(a, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(b, 0o755); err != nil {
		t.Fatal(err)
	}
	sources := []BackupSource{
		NewBackupSource(a, "A"),
		NewBackupSource(b, "B"),
	}
	if err := ThrowIfOverlapping(sources); err != nil {
		t.Fatal(err)
	}
}

func TestIsSameOrPrefixExactAndNested(t *testing.T) {
	if !IsSameOrPrefix("/data/docs", "/data/docs") {
		t.Fatal("same")
	}
	if !IsSameOrPrefix("/data/docs", "/data/docs/child") {
		t.Fatal("nested")
	}
	if IsSameOrPrefix("/data/docs", "/data/docs2") {
		t.Fatal("prefix false friend")
	}
	if IsSameOrPrefix("/data/a", "/data/b") {
		t.Fatal("siblings")
	}
}

func TestFindOverlapsViaSymlink(t *testing.T) {
	root := t.TempDir()
	realDir := filepath.Join(root, "real")
	if err := os.Mkdir(realDir, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(realDir, link); err != nil {
		t.Fatal(err)
	}
	sources := []BackupSource{
		NewBackupSource(realDir, "Real"),
		NewBackupSource(link, "Link"),
	}
	pairs := FindOverlaps(sources)
	if len(pairs) == 0 {
		t.Fatal("expected symlink targets to overlap as same path")
	}
}
