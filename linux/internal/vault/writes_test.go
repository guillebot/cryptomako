package vault

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")
	n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, "")
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

func TestSyncRespectsExcludes(t *testing.T) {
	pass := "exclude-sync-pass"
	root := t.TempDir()
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	clearDir := t.TempDir()
	keep := filepath.Join(clearDir, "keep")
	skipDir := filepath.Join(clearDir, "node_modules", "pkg")
	if err := os.MkdirAll(keep, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(skipDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(keep, "ok.txt"), []byte("ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(skipDir, "ignored.js"), []byte("nope\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(clearDir, ".DS_Store"), []byte("junk"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(clearDir, "x.pyc"), []byte("pyc"), 0o600); err != nil {
		t.Fatal(err)
	}

	ex := config.DefaultBackupSyncExcludes()
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")
	n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", &ex, nil, statePath, "")
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if n != 1 {
		t.Fatalf("synced %d want 1 (only keep/ok.txt)", n)
	}
	if _, err := s.Open("/keep/ok.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Open("/node_modules/pkg/ignored.js"); err == nil {
		t.Fatal("excluded node_modules file should not exist in vault")
	}
	if _, err := s.Open("/.DS_Store"); err == nil {
		t.Fatal("excluded .DS_Store should not exist")
	}
	if _, err := s.Open("/x.pyc"); err == nil {
		t.Fatal("excluded .pyc should not exist")
	}
}

func TestSyncHonorsPreferencesConcurrencyAndBandwidth(t *testing.T) {
	pass, ok := fixturePassword(t)
	if !ok {
		t.Skip("fixtures/PASSWORD missing")
	}
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
	for i := 0; i < 5; i++ {
		name := filepath.Join(clearDir, "f"+string(rune('a'+i))+".txt")
		if err := os.WriteFile(name, []byte("prefs-sync\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	prefs := config.DefaultAppPreferences()
	prefs.SyncSmallPutConcurrency = 2
	prefs.SyncMediumPutConcurrency = 1
	prefs.SyncLargePutConcurrency = 1
	prefs.LimitSyncUploadBandwidth = true
	prefs.SyncUploadCapMbps = 100 // high enough not to dominate test time
	if prefs.ClampedSmallPutConcurrency() != 2 {
		t.Fatalf("clamp small = %d", prefs.ClampedSmallPutConcurrency())
	}
	if config.UploadBandwidthLimiterFromPreferences(prefs) == nil {
		t.Fatal("expected bandwidth limiter when limit enabled")
	}
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")
	n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/prefs-sync", nil, &prefs, statePath, "")
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if n != 5 {
		t.Fatalf("synced %d", n)
	}
}

func TestSyncSkipsUnchangedFingerprint(t *testing.T) {
	pass := "fp-skip-pass"
	root := t.TempDir()
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	clearDir := t.TempDir()
	note := filepath.Join(clearDir, "note.txt")
	if err := os.WriteFile(note, []byte("same\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")

	n1, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, "")
	if err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if n1 != 1 {
		t.Fatalf("first synced %d", n1)
	}
	st := config.LoadBackupSyncState(statePath)
	folder := config.VaultFolderNameForSource(clearDir)
	key := config.BackupSyncStateKey(folder, "note.txt")
	if _, ok := st.Get(key); !ok {
		t.Fatalf("missing fingerprint for %s in %#v", key, st.Files)
	}

	n2, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, "")
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	if n2 != 0 {
		t.Fatalf("second sync should skip unchanged, got %d", n2)
	}
}

func TestSyncRewritesWhenSizeOrMtimeChanges(t *testing.T) {
	pass := "fp-rewrite-pass"
	root := t.TempDir()
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	clearDir := t.TempDir()
	note := filepath.Join(clearDir, "note.txt")
	if err := os.WriteFile(note, []byte("v1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")

	if n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, ""); err != nil || n != 1 {
		t.Fatalf("first: n=%d err=%v", n, err)
	}

	// Size change → must put again.
	if err := os.WriteFile(note, []byte("v2-longer\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, ""); err != nil || n != 1 {
		t.Fatalf("size change: n=%d err=%v", n, err)
	}
	r, err := s.Open("/note.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	r.Close()
	if string(got) != "v2-longer\n" {
		t.Fatalf("vault content %q", got)
	}

	// mtime-only change → must put again.
	info, err := os.Stat(note)
	if err != nil {
		t.Fatal(err)
	}
	newMtime := info.ModTime().Add(2 * time.Second)
	if err := os.Chtimes(note, newMtime, newMtime); err != nil {
		t.Fatal(err)
	}
	if n, _, err := s.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, ""); err != nil || n != 1 {
		t.Fatalf("mtime change: n=%d err=%v", n, err)
	}
}

func TestSyncPutFailureDoesNotUpdateFingerprint(t *testing.T) {
	pass := "fp-fail-pass"
	disk := t.TempDir()
	s, err := CreateFormat8(disk, pass)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()

	store := newMemStore()
	if err := seedMemFromDisk(store, disk); err != nil {
		t.Fatal(err)
	}
	s2, err := unlockWithStore(config.Config{Passphrase: pass}, store)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()

	clearDir := t.TempDir()
	note := filepath.Join(clearDir, "note.txt")
	if err := os.WriteFile(note, []byte("fail-me\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")
	folder := config.VaultFolderNameForSource(clearDir)
	key := config.BackupSyncStateKey(folder, "note.txt")

	store.failPut = true
	n, _, err := s2.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, "")
	if err == nil {
		t.Fatal("expected put failure")
	}
	if n != 0 {
		t.Fatalf("uploaded %d on failure", n)
	}
	st := config.LoadBackupSyncState(statePath)
	if _, ok := st.Get(key); ok {
		t.Fatal("fingerprint must not be recorded after failed put")
	}

	store.failPut = false
	if n, _, err := s2.SyncCleartextTree(context.Background(), clearDir, "/", nil, nil, statePath, ""); err != nil || n != 1 {
		t.Fatalf("retry: n=%d err=%v", n, err)
	}
	st = config.LoadBackupSyncState(statePath)
	if _, ok := st.Get(key); !ok {
		t.Fatal("fingerprint should exist after successful put")
	}
}

func TestSyncMultiSourceVaultFolderRouting(t *testing.T) {
	pass := "multi-src-pass"
	root := t.TempDir()
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")

	srcA := t.TempDir()
	srcB := t.TempDir()
	if err := os.WriteFile(filepath.Join(srcA, "a.txt"), []byte("aaa\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(srcB, "b.txt"), []byte("bbb\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	jobs := []config.SyncTarget{
		{SourcePath: srcA, DestPrefix: config.CleartextBackupDest("Alpha"), VaultFolderName: "Alpha"},
		{SourcePath: srcB, DestPrefix: config.CleartextBackupDest("Beta"), VaultFolderName: "Beta"},
	}
	total := 0
	for _, job := range jobs {
		n, _, err := s.SyncCleartextTree(context.Background(), job.SourcePath, job.DestPrefix, nil, nil, statePath, job.VaultFolderName)
		if err != nil {
			t.Fatalf("%s: %v", job.VaultFolderName, err)
		}
		total += n
	}
	if total != 2 {
		t.Fatalf("synced %d want 2", total)
	}

	st := config.LoadBackupSyncState(statePath)
	if _, ok := st.Get(config.BackupSyncStateKey("Alpha", "a.txt")); !ok {
		t.Fatalf("missing Alpha fingerprint: %#v", st.Files)
	}
	if _, ok := st.Get(config.BackupSyncStateKey("Beta", "b.txt")); !ok {
		t.Fatalf("missing Beta fingerprint: %#v", st.Files)
	}
	// Basename of temp dirs must NOT be used when vaultFolderName is explicit.
	for key := range st.Files {
		if key != "Alpha/a.txt" && key != "Beta/b.txt" {
			t.Fatalf("unexpected key %q", key)
		}
	}

	r, err := s.Open("/Backups/Alpha/a.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(r)
	r.Close()
	if string(got) != "aaa\n" {
		t.Fatalf("Alpha content %q", got)
	}
	r, err = s.Open("/Backups/Beta/b.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ = io.ReadAll(r)
	r.Close()
	if string(got) != "bbb\n" {
		t.Fatalf("Beta content %q", got)
	}

	// Second pass should skip unchanged for both vault folders.
	for _, job := range jobs {
		n, _, err := s.SyncCleartextTree(context.Background(), job.SourcePath, job.DestPrefix, nil, nil, statePath, job.VaultFolderName)
		if err != nil || n != 0 {
			t.Fatalf("skip %s: n=%d err=%v", job.VaultFolderName, n, err)
		}
	}
}

func TestSyncCleartextTreeCancelledContext(t *testing.T) {
	root := t.TempDir()
	pass := "cancel-sync-pass"
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	clearDir := t.TempDir()
	for i := 0; i < 5; i++ {
		if err := os.WriteFile(filepath.Join(clearDir, fmt.Sprintf("f%d.txt", i)), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	statePath := filepath.Join(t.TempDir(), "backup-sync-state.json")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	n, _, err := s.SyncCleartextTree(ctx, clearDir, "/", nil, nil, statePath, "")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got n=%d err=%v", n, err)
	}
}


func TestBackupModeKeepsVaultOrphans(t *testing.T) {
	root := t.TempDir()
	pass := "orphan-backup-pass"
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	dest := "/Backups/Docs"
	if err := s.PutFile(dest+"/keep.txt", []byte("keep")); err != nil {
		t.Fatal(err)
	}
	if err := s.PutFile(dest+"/orphan.txt", []byte("orphan")); err != nil {
		t.Fatal(err)
	}

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "keep.txt"), []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "state.json")
	prefs := config.DefaultAppPreferences() // backup mode
	uploaded, deleted, err := s.SyncCleartextTree(context.Background(), src, dest, nil, &prefs, statePath, "Docs")
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 0 {
		t.Fatalf("backup mode must not delete vault orphans, deleted=%d uploaded=%d", deleted, uploaded)
	}
	if _, err := s.Open(dest + "/orphan.txt"); err != nil {
		t.Fatalf("orphan should remain in backup mode: %v", err)
	}
	// Local source untouched
	if _, err := os.Stat(filepath.Join(src, "keep.txt")); err != nil {
		t.Fatal(err)
	}
}

func TestSyncModeDeletesVaultOrphansUnderDestOnly(t *testing.T) {
	root := t.TempDir()
	pass := "orphan-sync-pass"
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	dest := "/Backups/Photos"
	other := "/Backups/Other"
	if err := s.PutFile(dest+"/keep.txt", []byte("keep")); err != nil {
		t.Fatal(err)
	}
	if err := s.PutFile(dest+"/gone.txt", []byte("gone")); err != nil {
		t.Fatal(err)
	}
	if err := s.PutFile(other+"/safe.txt", []byte("safe")); err != nil {
		t.Fatal(err)
	}

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "keep.txt"), []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	statePath := filepath.Join(t.TempDir(), "state.json")
	prefs := config.DefaultAppPreferences()
	prefs.BackupTransferMode = config.BackupTransferModeSync
	uploaded, deleted, err := s.SyncCleartextTree(context.Background(), src, dest, nil, &prefs, statePath, "Photos")
	if err != nil {
		t.Fatal(err)
	}
	if deleted < 1 {
		t.Fatalf("expected orphan delete, deleted=%d uploaded=%d", deleted, uploaded)
	}
	if _, err := s.Open(dest + "/gone.txt"); err == nil {
		t.Fatal("vault orphan under dest should be deleted in sync mode")
	}
	if _, err := s.Open(other + "/safe.txt"); err != nil {
		t.Fatalf("files outside dest must not be deleted: %v", err)
	}
	if _, err := s.Open(dest + "/keep.txt"); err != nil {
		t.Fatalf("matching file should remain: %v", err)
	}
	// Never deletes local source
	if _, err := os.Stat(filepath.Join(src, "keep.txt")); err != nil {
		t.Fatal(err)
	}
}

func TestSyncModeRefusesVaultRootDest(t *testing.T) {
	root := t.TempDir()
	pass := "orphan-root-pass"
	s, err := CreateFormat8(root, pass)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("a"), 0o600); err != nil {
		t.Fatal(err)
	}
	prefs := config.DefaultAppPreferences()
	prefs.BackupTransferMode = config.BackupTransferModeSync
	statePath := filepath.Join(t.TempDir(), "state.json")
	_, _, err = s.SyncCleartextTree(context.Background(), src, "/", nil, &prefs, statePath, "Root")
	if err == nil {
		t.Fatal("expected error refusing vault root orphan prune")
	}
	if !strings.Contains(err.Error(), "vault root") {
		t.Fatalf("unexpected error: %v", err)
	}
}
