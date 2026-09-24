package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// BackupSyncExcludes mirrors Sources/CryptoMakoShared/BackupSyncExcludes.swift.
// JSON field names are locked with Platforms — do not invent new keys.
type BackupSyncExcludes struct {
	DirectoryNames []string `json:"directoryNames"`
	FileNames      []string `json:"fileNames"`
	FileExtensions []string `json:"fileExtensions"`
}

// backupSyncExcludesStore is the on-disk wrapper (macOS BackupSyncExcludesStore).
type backupSyncExcludesStore struct {
	Excludes           BackupSyncExcludes `json:"excludes"`
	DefaultsGeneration int                `json:"defaultsGeneration,omitempty"`
}

// DefaultBackupSyncExcludes matches macOS BackupSyncExcludes.default.
// DefaultsGeneration mirrors macOS BackupSyncExcludes.defaultsGeneration.
const DefaultsGeneration = 2

func directoryNamesAddedInGeneration2() []string {
	return []string{
		"DerivedData",
		"DerivedData-sim",
		"Index.noindex",
		"ModuleCache.noindex",
		".build",
		"build",
	}
}

func fileExtensionsAddedInGeneration2() []string {
	return []string{"swiftinterface"}
}

func DefaultBackupSyncExcludes() BackupSyncExcludes {
	dirs := []string{
		"node_modules",
		".git",
		"__pycache__",
		".svn",
		".hg",
		".tox",
		".venv",
		"venv",
		".idea",
		".next",
		"Pods",
	}
	dirs = append(dirs, directoryNamesAddedInGeneration2()...)
	exts := []string{"pyc", "pyo"}
	exts = append(exts, fileExtensionsAddedInGeneration2()...)
	return BackupSyncExcludes{
		DirectoryNames: dirs,
		FileNames: []string{
			".DS_Store",
			"Thumbs.db",
			"desktop.ini",
		},
		FileExtensions: exts,
	}
}

// DefaultExcludesPath returns ~/.config/cryptomako/backup-sync-excludes.json (XDG).
func DefaultExcludesPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "cryptomako", "backup-sync-excludes.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "cryptomako", "backup-sync-excludes.json")
	}
	return filepath.Join(home, ".config", "cryptomako", "backup-sync-excludes.json")
}

// LoadBackupSyncExcludes reads the macOS-compatible store JSON.
// Missing file → defaults. Empty/partial lists are used as-is (same as Swift decode).
func LoadBackupSyncExcludes(path string) (BackupSyncExcludes, error) {
	if path == "" {
		path = DefaultExcludesPath()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return DefaultBackupSyncExcludes(), nil
		}
		return BackupSyncExcludes{}, err
	}
	var store backupSyncExcludesStore
	if err := json.Unmarshal(data, &store); err != nil {
		return BackupSyncExcludes{}, err
	}
	if migrated := migrateShippedDefaults(&store); migrated {
		// Best-effort rewrite so next load skips migration.
		if out, err := json.Marshal(store); err == nil {
			_ = os.WriteFile(path, out, 0o600)
		}
	}
	return store.Excludes, nil
}

func containsString(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func unionStrings(base []string, add []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(base)+len(add))
	for _, s := range base {
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	for _, s := range add {
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	return out
}

// migrateShippedDefaults mirrors macOS BackupSyncExcludesStore.migrateShippedDefaultsIfNeeded.
func migrateShippedDefaults(store *backupSyncExcludesStore) bool {
	if store.DefaultsGeneration >= DefaultsGeneration {
		return false
	}
	looksLikePriorDefaults := containsString(store.Excludes.DirectoryNames, "node_modules") || store.DefaultsGeneration >= 1
	if looksLikePriorDefaults && store.DefaultsGeneration < 2 {
		store.Excludes.DirectoryNames = unionStrings(store.Excludes.DirectoryNames, directoryNamesAddedInGeneration2())
		store.Excludes.FileExtensions = unionStrings(store.Excludes.FileExtensions, fileExtensionsAddedInGeneration2())
	}
	store.DefaultsGeneration = DefaultsGeneration
	return true
}

func (e BackupSyncExcludes) dirSet() map[string]struct{} {
	m := make(map[string]struct{}, len(e.DirectoryNames))
	for _, n := range e.DirectoryNames {
		m[n] = struct{}{}
	}
	return m
}

func (e BackupSyncExcludes) fileSet() map[string]struct{} {
	m := make(map[string]struct{}, len(e.FileNames))
	for _, n := range e.FileNames {
		m[n] = struct{}{}
	}
	return m
}

func (e BackupSyncExcludes) extSet() map[string]struct{} {
	m := make(map[string]struct{}, len(e.FileExtensions))
	for _, n := range e.FileExtensions {
		m[strings.ToLower(n)] = struct{}{}
	}
	return m
}

// ShouldSkipDirectory reports whether a directory basename is excluded.
func (e BackupSyncExcludes) ShouldSkipDirectory(name string) bool {
	_, ok := e.dirSet()[name]
	return ok
}

// ShouldSkipFile reports whether a regular-file basename is excluded.
func (e BackupSyncExcludes) ShouldSkipFile(name string) bool {
	if _, ok := e.fileSet()[name]; ok {
		return true
	}
	if !strings.Contains(name, ".") {
		return false
	}
	ext := name[strings.LastIndex(name, ".")+1:]
	if ext == "" || ext == name {
		return false
	}
	_, ok := e.extSet()[strings.ToLower(ext)]
	return ok
}

// ShouldSkipRelativePath is true when any slash-separated component is an
// excluded directory or file (belt-and-suspenders vs enumerator SkipDir).
func (e BackupSyncExcludes) ShouldSkipRelativePath(relativePath string) bool {
	for _, part := range strings.Split(relativePath, "/") {
		if part == "" || part == "." {
			continue
		}
		if e.ShouldSkipDirectory(part) {
			return true
		}
		if e.ShouldSkipFile(part) {
			return true
		}
	}
	return false
}
