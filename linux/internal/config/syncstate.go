package config

import (
	"encoding/json"
	"math"
	"os"
	"strings"
	"path/filepath"
	"time"
)

// AppleReferenceDateUnix is 2001-01-01 00:00:00 UTC as Unix seconds.
// macOS BackupFileFingerprint.contentModification is TimeInterval since this
// Apple reference date (Foundation Date.timeIntervalSinceReferenceDate).
const AppleReferenceDateUnix int64 = 978307200

// Threshold for fingerprint mtime match (same as Swift abs(...) < 0.001).
const fingerprintMtimeEpsilon = 0.001

// BackupFileFingerprint mirrors Sources/CryptoMakoShared/BackupSyncState.swift.
// JSON keys are Platforms-locked: size, contentModification.
type BackupFileFingerprint struct {
	Size                int64   `json:"size"`
	ContentModification float64 `json:"contentModification"`
}

// NewBackupFileFingerprint builds a fingerprint from cleartext size + mtime.
// contentModification is seconds since 2001-01-01 UTC (Apple reference date).
func NewBackupFileFingerprint(size int64, mtime time.Time) BackupFileFingerprint {
	return BackupFileFingerprint{
		Size:                size,
		ContentModification: ContentModificationFromTime(mtime),
	}
}

// ContentModificationFromTime encodes mtime as Apple reference-date seconds.
func ContentModificationFromTime(t time.Time) float64 {
	return float64(t.UnixNano())/1e9 - float64(AppleReferenceDateUnix)
}

// Matches reports whether size and mtime agree with this fingerprint
// (mtime within 1 ms, matching Swift BackupFileFingerprint.matches).
func (f BackupFileFingerprint) Matches(size int64, mtime time.Time) bool {
	cm := ContentModificationFromTime(mtime)
	return f.Size == size && math.Abs(f.ContentModification-cm) < fingerprintMtimeEpsilon
}

// BackupSyncState mirrors Sources/CryptoMakoShared/BackupSyncState.swift.
// Key: "{vaultFolder}/{relativePath}" (see BackupSyncStateKey).
type BackupSyncState struct {
	Files map[string]BackupFileFingerprint `json:"files"`
}

// EmptyBackupSyncState returns an empty index.
func EmptyBackupSyncState() BackupSyncState {
	return BackupSyncState{Files: map[string]BackupFileFingerprint{}}
}

// BackupSyncStateKey matches Swift BackupSyncState.key(vaultFolder:relativePath:).
func BackupSyncStateKey(vaultFolder, relativePath string) string {
	return vaultFolder + "/" + relativePath
}

// VaultFolderNameForSource matches macOS BackupSource default:
// last path component of the cleartext source root, or "Backup" if empty.
func VaultFolderNameForSource(localRoot string) string {
	name := filepath.Base(filepath.Clean(localRoot))
	if name == "" || name == "." || name == string(filepath.Separator) {
		return "Backup"
	}
	return name
}

// DefaultSyncStatePath returns ~/.config/cryptomako/backup-sync-state.json (XDG).
// Same filename as macOS app-group backup-sync-state.json (macOS stores it under
// the CryptoMako app group container, not XDG).
func DefaultSyncStatePath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "cryptomako", "backup-sync-state.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "cryptomako", "backup-sync-state.json")
	}
	return filepath.Join(home, ".config", "cryptomako", "backup-sync-state.json")
}

// LoadBackupSyncState reads the macOS-compatible JSON index.
// Missing/unreadable/invalid → empty (same soft-fail as Swift BackupSyncState.load).
func LoadBackupSyncState(path string) BackupSyncState {
	if path == "" {
		path = DefaultSyncStatePath()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return EmptyBackupSyncState()
	}
	var st BackupSyncState
	if err := json.Unmarshal(data, &st); err != nil {
		return EmptyBackupSyncState()
	}
	if st.Files == nil {
		st.Files = map[string]BackupFileFingerprint{}
	}
	return st
}

// Get returns the fingerprint for key, if present.
func (s BackupSyncState) Get(key string) (BackupFileFingerprint, bool) {
	if s.Files == nil {
		return BackupFileFingerprint{}, false
	}
	fp, ok := s.Files[key]
	return fp, ok
}

// Set records a fingerprint after a successful put (caller must not call on failure).
func (s *BackupSyncState) Set(key string, fp BackupFileFingerprint) {
	if s.Files == nil {
		s.Files = map[string]BackupFileFingerprint{}
	}
	s.Files[key] = fp
}


// Remove deletes one fingerprint key (after vault orphan delete).
func (s *BackupSyncState) Remove(key string) {
	if s.Files == nil {
		return
	}
	delete(s.Files, key)
}

// RemoveUnder clears fingerprint keys for a relative path under vaultFolder.
// For directories, also removes all nested keys (prefix match).
func (s *BackupSyncState) RemoveUnder(vaultFolder, relativePath string, isDirectory bool) {
	if s.Files == nil {
		return
	}
	base := BackupSyncStateKey(vaultFolder, relativePath)
	if !isDirectory {
		delete(s.Files, base)
		return
	}
	prefix := base + "/"
	for k := range s.Files {
		if k == base || strings.HasPrefix(k, prefix) {
			delete(s.Files, k)
		}
	}
}

// Save persists the index atomically. Best-effort: never returns an error that
// should fail a sync (matches Swift BackupSyncState.save).
func (s BackupSyncState) Save(path string) {
	if path == "" {
		path = DefaultSyncStatePath()
	}
	if s.Files == nil {
		s.Files = map[string]BackupFileFingerprint{}
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, path)
}
