package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestContentModificationAppleEpoch(t *testing.T) {
	// 2001-01-01 00:00:00 UTC → 0
	ref := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	if got := ContentModificationFromTime(ref); got != 0 {
		t.Fatalf("ref date → %v want 0", got)
	}
	// Unix epoch 1970-01-01 → -978307200
	unix := time.Unix(0, 0).UTC()
	if got := ContentModificationFromTime(unix); got != -float64(AppleReferenceDateUnix) {
		t.Fatalf("unix epoch → %v", got)
	}
}

func TestFingerprintMatchesEpsilon(t *testing.T) {
	mtime := time.Date(2024, 6, 15, 12, 0, 0, 0, time.UTC)
	fp := NewBackupFileFingerprint(42, mtime)
	if !fp.Matches(42, mtime) {
		t.Fatal("exact match")
	}
	if !fp.Matches(42, mtime.Add(500*time.Microsecond)) {
		t.Fatal("within 1ms should match")
	}
	if fp.Matches(42, mtime.Add(2*time.Millisecond)) {
		t.Fatal("2ms should not match")
	}
	if fp.Matches(43, mtime) {
		t.Fatal("size mismatch")
	}
}

func TestBackupSyncStateKeyAndVaultFolder(t *testing.T) {
	if got := BackupSyncStateKey("Documents", "a/b.txt"); got != "Documents/a/b.txt" {
		t.Fatalf("%q", got)
	}
	if got := VaultFolderNameForSource("/home/u/Photos"); got != "Photos" {
		t.Fatalf("%q", got)
	}
	if got := VaultFolderNameForSource("/"); got != "Backup" {
		t.Fatalf("root → %q want Backup", got)
	}
}

func TestLoadSaveRoundTripJSONKeys(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "backup-sync-state.json")
	mtime := time.Date(2022, 1, 2, 3, 4, 5, 0, time.UTC)
	st := EmptyBackupSyncState()
	st.Set(BackupSyncStateKey("Docs", "note.txt"), NewBackupFileFingerprint(7, mtime))
	st.Save(path)

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		t.Fatal(err)
	}
	if _, ok := probe["files"]; !ok {
		t.Fatalf("missing files key: %s", raw)
	}
	var decoded struct {
		Files map[string]struct {
			Size                int64   `json:"size"`
			ContentModification float64 `json:"contentModification"`
		} `json:"files"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	fp, ok := decoded.Files["Docs/note.txt"]
	if !ok {
		t.Fatalf("key missing: %s", raw)
	}
	if fp.Size != 7 {
		t.Fatalf("size %d", fp.Size)
	}
	wantCM := ContentModificationFromTime(mtime)
	if fp.ContentModification != wantCM {
		t.Fatalf("contentModification %v want %v", fp.ContentModification, wantCM)
	}

	loaded := LoadBackupSyncState(path)
	got, ok := loaded.Get("Docs/note.txt")
	if !ok || !got.Matches(7, mtime) {
		t.Fatalf("reload %#v ok=%v", got, ok)
	}
}

func TestLoadMissingEmpty(t *testing.T) {
	st := LoadBackupSyncState(filepath.Join(t.TempDir(), "nope.json"))
	if len(st.Files) != 0 {
		t.Fatalf("%d", len(st.Files))
	}
}

func TestDefaultSyncStatePathUsesXDG(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/xdg-sync")
	got := DefaultSyncStatePath()
	want := "/tmp/xdg-sync/cryptomako/backup-sync-state.json"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestSaveBestEffortDoesNotPanic(t *testing.T) {
	st := EmptyBackupSyncState()
	st.Set("a/b", NewBackupFileFingerprint(1, time.Now()))
	// Unwritable parent: best-effort swallow.
	st.Save("/proc/does-not-exist-cryptomako/backup-sync-state.json")
}
