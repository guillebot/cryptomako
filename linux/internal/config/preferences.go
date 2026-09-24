package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// EnvProxyPassword is the Linux analog of the macOS Keychain proxy password.
// Never store the proxy password in app-preferences.json.
const EnvProxyPassword = "CRYPTOMAKO_PROXY_PASSWORD"

// ProxyMode values (locked with macOS AppPreferences.ProxyMode raw values).
const (
	ProxyModeSystem = "system"
	ProxyModeDirect = "direct"
	ProxyModeCustom = "custom"
)

// BackupTransferMode values (locked with macOS AppPreferences.BackupTransferMode).
// Prefs key: backupTransferMode. Default backup (safer: no vault deletes).
const (
	BackupTransferModeBackup = "backup"
	BackupTransferModeSync   = "sync"
)

// AppPreferences mirrors Sources/CryptoMakoShared/AppPreferences.swift.
// JSON field names are Platforms-locked — do not invent new keys.
// Unknown JSON keys are ignored (encoding/json default).
type AppPreferences struct {
	ProxyMode     string `json:"proxyMode"`
	ProxyHost     string `json:"proxyHost"`
	ProxyPort     int    `json:"proxyPort"`
	ProxyUsername string `json:"proxyUsername"`

	// BackupTransferMode is "backup" | "sync" (macOS AppPreferences.backupTransferMode).
	// backup = put/update only; sync = backup + delete vault ciphertext orphans under
	// that source's Backups/<folder>/ only. Never deletes the local source.
	BackupTransferMode string `json:"backupTransferMode"`

	LimitSyncUploadBandwidth bool    `json:"limitSyncUploadBandwidth"`
	SyncUploadCapMbps        float64 `json:"syncUploadCapMbps"`

	SyncSmallPutConcurrency  int `json:"syncSmallPutConcurrency"`
	SyncMediumPutConcurrency int `json:"syncMediumPutConcurrency"`
	SyncLargePutConcurrency  int `json:"syncLargePutConcurrency"`
}

// DefaultAppPreferences matches AppPreferences.default / init defaults on macOS.
func DefaultAppPreferences() AppPreferences {
	return AppPreferences{
		ProxyMode:                ProxyModeSystem,
		ProxyHost:                "",
		ProxyPort:                8080,
		ProxyUsername:            "",
		BackupTransferMode:       BackupTransferModeBackup,
		LimitSyncUploadBandwidth: false,
		SyncUploadCapMbps:        50,
		SyncSmallPutConcurrency:  96,
		SyncMediumPutConcurrency: 32,
		SyncLargePutConcurrency:  4,
	}
}

// DefaultPreferencesPath returns ~/.config/cryptomako/app-preferences.json (XDG).
func DefaultPreferencesPath() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "cryptomako", "app-preferences.json")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "cryptomako", "app-preferences.json")
	}
	return filepath.Join(home, ".config", "cryptomako", "app-preferences.json")
}

// ProxyPassword returns CRYPTOMAKO_PROXY_PASSWORD (empty if unset).
func ProxyPassword() string {
	return os.Getenv(EnvProxyPassword)
}

// ClampSyncWorkers clamps worker knobs to safe ranges (fail-closed).
func (p *AppPreferences) ClampSyncWorkers() {
	p.SyncSmallPutConcurrency = clampInt(p.SyncSmallPutConcurrency, 1, 256)
	p.SyncMediumPutConcurrency = clampInt(p.SyncMediumPutConcurrency, 1, 128)
	p.SyncLargePutConcurrency = clampInt(p.SyncLargePutConcurrency, 1, 16)
	if p.SyncUploadCapMbps < 1 {
		p.SyncUploadCapMbps = 1
	}
}

// ClampedSmallPutConcurrency is syncSmallPutConcurrency in 1–256.
func (p AppPreferences) ClampedSmallPutConcurrency() int {
	return clampInt(p.SyncSmallPutConcurrency, 1, 256)
}

// ClampedMediumPutConcurrency is syncMediumPutConcurrency in 1–128.
func (p AppPreferences) ClampedMediumPutConcurrency() int {
	return clampInt(p.SyncMediumPutConcurrency, 1, 128)
}

// ClampedLargePutConcurrency is syncLargePutConcurrency in 1–16.
func (p AppPreferences) ClampedLargePutConcurrency() int {
	return clampInt(p.SyncLargePutConcurrency, 1, 16)
}

// SyncUploadBytesPerSecond is the Sync pacing budget, or 0 when unlimited.
func (p AppPreferences) SyncUploadBytesPerSecond() float64 {
	if !p.LimitSyncUploadBandwidth || p.SyncUploadCapMbps <= 0 {
		return 0
	}
	mbps := p.SyncUploadCapMbps
	if mbps < 1 {
		mbps = 1
	}
	return mbps * 1_000_000 / 8
}

// ParseAppPreferences decodes JSON. Unknown keys are ignored.
// Missing fields take macOS defaults. Secrets in JSON are rejected.
func ParseAppPreferences(data []byte) (AppPreferences, error) {
	p := DefaultAppPreferences()
	if len(bytes.TrimSpace(data)) == 0 {
		return p, nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return AppPreferences{}, err
	}
	for _, banned := range bannedSecretJSONKeys {
		if _, ok := raw[banned]; ok {
			return AppPreferences{}, fmt.Errorf("app-preferences must not contain %q (use env %s for proxy password)", banned, EnvProxyPassword)
		}
	}
	if err := json.Unmarshal(data, &p); err != nil {
		return AppPreferences{}, err
	}
	if strings.TrimSpace(p.ProxyMode) == "" {
		p.ProxyMode = ProxyModeSystem
	}
	p.BackupTransferMode = NormalizeBackupTransferMode(p.BackupTransferMode)
	return p, nil
}

// NormalizeBackupTransferMode returns "sync" only for that exact mode; anything
// else (empty, unknown) fails closed to "backup" (no vault deletes).
func NormalizeBackupTransferMode(mode string) string {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case BackupTransferModeSync:
		return BackupTransferModeSync
	default:
		return BackupTransferModeBackup
	}
}

// IsSyncTransferMode reports whether prefs select Sync (orphan vault deletes).
func (p AppPreferences) IsSyncTransferMode() bool {
	return NormalizeBackupTransferMode(p.BackupTransferMode) == BackupTransferModeSync
}

// LoadAppPreferences reads path (default XDG). Missing/unreadable → defaults
// (same soft-fail as macOS AppPreferences.load).
// If the file contains banned secret keys, soft-fail still applies (defaults)
// but a warning is written to stderr so secrets are not silently ignored on disk.
func LoadAppPreferences(path string) AppPreferences {
	if path == "" {
		path = DefaultPreferencesPath()
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return DefaultAppPreferences()
	}
	p, err := ParseAppPreferences(data)
	if err != nil {
		if strings.Contains(err.Error(), "must not contain") {
			fmt.Fprintf(os.Stderr, "cryptomako: refusing secret keys in %s (%v); using defaults\n", path, err)
		}
		return DefaultAppPreferences()
	}
	return p
}

// SaveAppPreferences writes prefs (clamped) as pretty JSON with sorted keys.
func SaveAppPreferences(path string, prefs AppPreferences) error {
	if path == "" {
		path = DefaultPreferencesPath()
	}
	prefs.ClampSyncWorkers()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := prefs.MarshalJSONPretty()
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// MarshalJSONPretty encodes with indent and sorted object keys.
func (p AppPreferences) MarshalJSONPretty() ([]byte, error) {
	// Stable key order matching Swift sortedKeys for reviewability.
	type ordered struct {
		ProxyMode                string  `json:"proxyMode"`
		ProxyHost                string  `json:"proxyHost"`
		ProxyPort                int     `json:"proxyPort"`
		ProxyUsername            string  `json:"proxyUsername"`
		BackupTransferMode       string  `json:"backupTransferMode"`
		LimitSyncUploadBandwidth bool    `json:"limitSyncUploadBandwidth"`
		SyncUploadCapMbps        float64 `json:"syncUploadCapMbps"`
		SyncSmallPutConcurrency  int     `json:"syncSmallPutConcurrency"`
		SyncMediumPutConcurrency int     `json:"syncMediumPutConcurrency"`
		SyncLargePutConcurrency  int     `json:"syncLargePutConcurrency"`
	}
	o := ordered{
		ProxyMode:                p.ProxyMode,
		ProxyHost:                p.ProxyHost,
		ProxyPort:                p.ProxyPort,
		ProxyUsername:            p.ProxyUsername,
		BackupTransferMode:       NormalizeBackupTransferMode(p.BackupTransferMode),
		LimitSyncUploadBandwidth: p.LimitSyncUploadBandwidth,
		SyncUploadCapMbps:        p.SyncUploadCapMbps,
		SyncSmallPutConcurrency:  p.SyncSmallPutConcurrency,
		SyncMediumPutConcurrency: p.SyncMediumPutConcurrency,
		SyncLargePutConcurrency:  p.SyncLargePutConcurrency,
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(o); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
