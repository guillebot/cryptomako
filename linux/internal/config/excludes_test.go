package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultExcludesSkipKnownJunk(t *testing.T) {
	e := DefaultBackupSyncExcludes()
	if !e.ShouldSkipDirectory("node_modules") {
		t.Fatal("expected skip node_modules")
	}
	if !e.ShouldSkipDirectory(".git") {
		t.Fatal("expected skip .git")
	}
	if e.ShouldSkipDirectory("src") {
		t.Fatal("src must not be skipped")
	}
	if !e.ShouldSkipFile(".DS_Store") {
		t.Fatal("expected skip .DS_Store")
	}
	if !e.ShouldSkipFile("mod.pyc") {
		t.Fatal("expected skip .pyc")
	}
	if e.ShouldSkipFile("readme.md") {
		t.Fatal("readme.md must not be skipped")
	}
	if !e.ShouldSkipRelativePath("proj/node_modules/pkg/index.js") {
		t.Fatal("expected skip via excluded dir component")
	}
	if !e.ShouldSkipRelativePath("a/.DS_Store") {
		t.Fatal("expected skip via excluded file component")
	}
	if e.ShouldSkipRelativePath("a/b/note.txt") {
		t.Fatal("normal path must not be skipped")
	}
}

func TestLoadExcludesMissingUsesDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.json")
	got, err := LoadBackupSyncExcludes(path)
	if err != nil {
		t.Fatal(err)
	}
	def := DefaultBackupSyncExcludes()
	if len(got.DirectoryNames) != len(def.DirectoryNames) {
		t.Fatalf("dirs %d want %d", len(got.DirectoryNames), len(def.DirectoryNames))
	}
}

func TestLoadExcludesCustomJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-sync-excludes.json")
	body := `{"excludes":{"directoryNames":["vendor"],"fileNames":["SKIP.me"],"fileExtensions":["tmp"]}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := LoadBackupSyncExcludes(path)
	if err != nil {
		t.Fatal(err)
	}
	if !got.ShouldSkipDirectory("vendor") {
		t.Fatal("vendor")
	}
	if got.ShouldSkipDirectory("node_modules") {
		t.Fatal("custom file replaces defaults — node_modules not listed")
	}
	if !got.ShouldSkipFile("SKIP.me") {
		t.Fatal("SKIP.me")
	}
	if !got.ShouldSkipFile("x.tmp") {
		t.Fatal(".tmp")
	}
}

func TestDefaultExcludesPathUsesXDG(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/xdg-ex")
	got := DefaultExcludesPath()
	want := "/tmp/xdg-ex/cryptomako/backup-sync-excludes.json"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}
