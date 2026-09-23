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
	Excludes BackupSyncExcludes `json:"excludes"`
}

// DefaultBackupSyncExcludes matches macOS BackupSyncExcludes.default.
func DefaultBackupSyncExcludes() BackupSyncExcludes {
	return BackupSyncExcludes{
		DirectoryNames: []string{
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
		},
		FileNames: []string{
			".DS_Store",
			"Thumbs.db",
			"desktop.ini",
		},
		FileExtensions: []string{
			"pyc",
			"pyo",
		},
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
	return store.Excludes, nil
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
