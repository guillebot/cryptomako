package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultBackupSourcesPathUsesXDG(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/xdg-sources")
	got := DefaultBackupSourcesPath()
	want := "/tmp/xdg-sources/cryptomako/backup-sources.json"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestLoadBackupSourcesMissingEmpty(t *testing.T) {
	st := LoadBackupSources(filepath.Join(t.TempDir(), "nope.json"))
	if len(st.Sources) != 0 {
		t.Fatalf("%d", len(st.Sources))
	}
}

func TestNewBackupSourceDefaultsVaultFolder(t *testing.T) {
	src := NewBackupSource("/home/u/Photos", "")
	if src.VaultFolderName != "Photos" {
		t.Fatalf("vaultFolderName=%q", src.VaultFolderName)
	}
	if src.ID == "" || src.Path == "" {
		t.Fatal("id/path required")
	}
	if src.AddedAt == 0 {
		t.Fatal("addedAt should be set")
	}
	custom := NewBackupSource("/home/u/Photos", "MyPhotos")
	if custom.VaultFolderName != "MyPhotos" {
		t.Fatalf("%q", custom.VaultFolderName)
	}
}

func TestBackupSourcesLoadSaveRoundTripJSONKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-sources.json")
	st := EmptyBackupSourcesStore()
	src, added, err := st.Add("/tmp/docs-a", "Documents")
	if err != nil || !added {
		t.Fatalf("add: added=%v err=%v", added, err)
	}
	if err := st.Save(path); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatal(err)
	}
	if _, ok := probe["sources"]; !ok {
		t.Fatalf("missing sources key: %s", raw)
	}
	var decoded struct {
		Sources []struct {
			ID              string  `json:"id"`
			Path            string  `json:"path"`
			VaultFolderName string  `json:"vaultFolderName"`
			AddedAt         float64 `json:"addedAt"`
		} `json:"sources"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Sources) != 1 {
		t.Fatalf("%d sources", len(decoded.Sources))
	}
	got := decoded.Sources[0]
	if got.ID != src.ID || got.VaultFolderName != "Documents" {
		t.Fatalf("%+v", got)
	}
	if got.AddedAt == 0 {
		t.Fatal("addedAt missing")
	}

	loaded := LoadBackupSources(path)
	if len(loaded.Sources) != 1 || loaded.Sources[0].VaultFolderName != "Documents" {
		t.Fatalf("%+v", loaded)
	}
}

func TestAddDedupesPathAndRemove(t *testing.T) {
	st := EmptyBackupSourcesStore()
	a, added, err := st.Add("/tmp/same", "")
	if err != nil || !added {
		t.Fatal(err)
	}
	_, added2, err := st.Add("/tmp/same", "Other")
	if err != nil || added2 {
		t.Fatalf("expected dedupe, added=%v err=%v", added2, err)
	}
	if len(st.Sources) != 1 {
		t.Fatalf("%d", len(st.Sources))
	}
	if !st.Remove(a.ID) {
		t.Fatal("remove by id")
	}
	if len(st.Sources) != 0 {
		t.Fatal("not empty")
	}
}

func TestCleartextBackupDest(t *testing.T) {
	if got := CleartextBackupDest("Documents"); got != "/Backups/Documents" {
		t.Fatalf("%q", got)
	}
	if got := CleartextBackupDest(""); got != "/Backups/Backup" {
		t.Fatalf("%q", got)
	}
}

func TestResolveSyncTargetsFromFlags(t *testing.T) {
	jobs, err := ResolveSyncTargets("/data/Photos", "/custom", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 1 {
		t.Fatalf("%d", len(jobs))
	}
	if jobs[0].SourcePath != "/data/Photos" || jobs[0].DestPrefix != "/custom" || jobs[0].VaultFolderName != "Photos" {
		t.Fatalf("%+v", jobs[0])
	}
}

func TestResolveSyncTargetsFromStoreMultiSource(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-sources.json")
	body := `{
  "sources": [
    {"id":"1","path":"/data/A","vaultFolderName":"Alpha","addedAt":1},
    {"id":"2","path":"/data/B","vaultFolderName":"Beta","addedAt":2}
  ]
}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	jobs, err := ResolveSyncTargets("", "/", path)
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 2 {
		t.Fatalf("%d", len(jobs))
	}
	if jobs[0].DestPrefix != "/Backups/Alpha" || jobs[0].VaultFolderName != "Alpha" || jobs[0].SourcePath != "/data/A" {
		t.Fatalf("job0 %+v", jobs[0])
	}
	if jobs[1].DestPrefix != "/Backups/Beta" || jobs[1].VaultFolderName != "Beta" {
		t.Fatalf("job1 %+v", jobs[1])
	}
}

func TestResolveSyncTargetsEmptyStoreErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.json")
	if err := os.WriteFile(path, []byte(`{"sources":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := ResolveSyncTargets("", "/", path)
	if err == nil {
		t.Fatal("expected helpful error")
	}
}

func TestDecodeMacOSStyleAddedAtNumber(t *testing.T) {
	// Swift JSONEncoder encodes Date as timeIntervalSinceReferenceDate (number).
	raw := `{"sources":[{"id":"x","path":"/p","vaultFolderName":"P","addedAt":700000000.5}]}`
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-sources.json")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	st := LoadBackupSources(path)
	if len(st.Sources) != 1 || st.Sources[0].AddedAt != 700000000.5 {
		t.Fatalf("%+v", st)
	}
}
