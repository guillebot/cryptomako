package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
)

// BackupSource mirrors Sources/CryptoMakoShared/BackupSources.swift.
// JSON keys are Platforms-locked — do not invent new keys.
// addedAt is seconds since Apple reference date 2001-01-01 UTC
// (Swift JSONEncoder.deferredToDate / Date.timeIntervalSinceReferenceDate).
type BackupSource struct {
	ID              string  `json:"id"`
	Path            string  `json:"path"`
	VaultFolderName string  `json:"vaultFolderName"`
	AddedAt         float64 `json:"addedAt"`
}

// BackupSourcesStore mirrors Sources/CryptoMakoShared/BackupSources.swift.
type BackupSourcesStore struct {
	Sources []BackupSource `json:"sources"`
}

// EmptyBackupSourcesStore returns a store with no sources.
func EmptyBackupSourcesStore() BackupSourcesStore {
	return BackupSourcesStore{Sources: []BackupSource{}}
}

// NewBackupSource builds a source with a fresh id and default vaultFolderName
// (last path component, or "Backup" if empty) — same as Swift BackupSource.init.
func NewBackupSource(path string, vaultFolderName string) BackupSource {
	path = strings.TrimSpace(path)
	name := strings.TrimSpace(vaultFolderName)
	if name == "" {
		name = VaultFolderNameForSource(path)
	}
	if name == "" {
		name = "Backup"
	}
	return BackupSource{
		ID:              uuid.NewString(),
		Path:            path,
		VaultFolderName: name,
		AddedAt:         ContentModificationFromTime(time.Now().UTC()),
	}
}

// DefaultBackupSourcesPath returns ~/.config/cryptomako/backup-sources.json (XDG).
// Same filename as macOS app-group backup-sources.json.
func DefaultBackupSourcesPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "cryptomako", "backup-sources.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "cryptomako", "backup-sources.json")
	}
	return filepath.Join(home, ".config", "cryptomako", "backup-sources.json")
}

// LoadBackupSources reads the macOS-compatible store JSON.
// Missing/unreadable/invalid → empty (same soft-fail as Swift BackupSourcesStore.load).
func LoadBackupSources(path string) BackupSourcesStore {
	if path == "" {
		path = DefaultBackupSourcesPath()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return EmptyBackupSourcesStore()
	}
	var store BackupSourcesStore
	if err := json.Unmarshal(data, &store); err != nil {
		return EmptyBackupSourcesStore()
	}
	if store.Sources == nil {
		store.Sources = []BackupSource{}
	}
	return store
}

// Save persists the store atomically (0600), creating the parent directory.
func (s BackupSourcesStore) Save(path string) error {
	if path == "" {
		path = DefaultBackupSourcesPath()
	}
	if s.Sources == nil {
		s.Sources = []BackupSource{}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Add appends a source unless the same absolute path is already listed.
// Returns the added (or existing) source and whether it was newly inserted.
func (s *BackupSourcesStore) Add(path, vaultFolderName string) (BackupSource, bool, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return BackupSource{}, false, fmt.Errorf("empty source path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return BackupSource{}, false, err
	}
	for _, existing := range s.Sources {
		if existing.Path == abs || existing.Path == path {
			return existing, false, nil
		}
	}
	src := NewBackupSource(abs, vaultFolderName)
	s.Sources = append(s.Sources, src)
	return src, true, nil
}

// Remove deletes the first source matching id or path. Returns true if removed.
func (s *BackupSourcesStore) Remove(idOrPath string) bool {
	idOrPath = strings.TrimSpace(idOrPath)
	if idOrPath == "" {
		return false
	}
	abs, absErr := filepath.Abs(idOrPath)
	kept := s.Sources[:0]
	removed := false
	for _, src := range s.Sources {
		if src.ID == idOrPath || src.Path == idOrPath || (absErr == nil && src.Path == abs) {
			removed = true
			continue
		}
		kept = append(kept, src)
	}
	if removed {
		s.Sources = kept
	}
	return removed
}

// SyncTarget is one cleartext → vault sync job resolved from CLI flags or
// backup-sources.json (macOS Backup Sync routing).
type SyncTarget struct {
	SourcePath      string
	DestPrefix      string // absolute cleartext path inside the vault
	VaultFolderName string // fingerprint key prefix
}

// CleartextBackupDest matches macOS BackupSyncEngine: Backups/{vaultFolderName}.
func CleartextBackupDest(vaultFolderName string) string {
	name := strings.Trim(strings.TrimSpace(vaultFolderName), "/")
	if name == "" {
		name = "Backup"
	}
	return "/Backups/" + name
}

// ResolveSyncTargets picks sync jobs:
//   - With --source: single job using --dest (default "/") and vault folder from
//     the source basename (current single-source CLI behavior).
//   - Without --source: if backup-sources.json has entries, one job per source
//     to /Backups/{vaultFolderName}/; if empty, returns a helpful error.
func ResolveSyncTargets(sourceFlag, destFlag, sourcesPath string) ([]SyncTarget, error) {
	if strings.TrimSpace(sourceFlag) != "" {
		dest := strings.TrimSpace(destFlag)
		if dest == "" {
			dest = "/"
		}
		return []SyncTarget{{
			SourcePath:      sourceFlag,
			DestPrefix:      dest,
			VaultFolderName: VaultFolderNameForSource(sourceFlag),
		}}, nil
	}
	store := LoadBackupSources(sourcesPath)
	if len(store.Sources) == 0 {
		return nil, fmt.Errorf("missing --source (and ~/.config/cryptomako/backup-sources.json is empty); add folders with `cryptomako sources add PATH` or pass --source / --dest")
	}
	out := make([]SyncTarget, 0, len(store.Sources))
	for _, src := range store.Sources {
		folder := strings.TrimSpace(src.VaultFolderName)
		if folder == "" {
			folder = VaultFolderNameForSource(src.Path)
		}
		out = append(out, SyncTarget{
			SourcePath:      src.Path,
			DestPrefix:      CleartextBackupDest(folder),
			VaultFolderName: folder,
		})
	}
	return out, nil
}
