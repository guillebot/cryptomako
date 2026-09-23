package vault

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// vaultCryptomatorJSON is the vault.cryptomator JWT wrapper metadata we can
// inspect without decrypting (format + claims header only partially).
// Full unlock requires cryptolib — see Unlock TODOs.
type vaultCryptomatorJSON struct {
	Version      int             `json:"version"` // sometimes present outside JWT
	Raw          json.RawMessage `json:"-"`
}

// Meta is non-secret vault identity after a best-effort local peek.
type Meta struct {
	Format           int
	CipherCombo      string
	RootCipherPrefix string
}

// CipherDirPrefix builds the Cryptomator d/<2>/<rest>/ layout path segment.
//
// TODO(platforms): hash must come from cryptor.encryptDirId — this helper only
// assembles the path once Platforms provides the hash string.
func CipherDirPrefix(vaultPrefix, dirIdHash string) string {
	vaultPrefix = strings.TrimSuffix(vaultPrefix, "/")
	dirIdHash = strings.TrimSpace(dirIdHash)
	if len(dirIdHash) < 3 {
		return ""
	}
	head := dirIdHash[:2]
	tail := dirIdHash[2:]
	base := "d/" + head + "/" + tail + "/"
	if vaultPrefix == "" {
		return base
	}
	return vaultPrefix + "/" + base
}

func readLocalVaultMeta(root string) (Meta, error) {
	path := filepath.Join(root, "vault.cryptomator")
	data, err := os.ReadFile(path)
	if err != nil {
		return Meta{}, fmt.Errorf("vault: read vault.cryptomator: %w", err)
	}
	// Format-8 vaults store a JWT in vault.cryptomator. Without cryptolib we
	// only confirm the file exists and report locked defaults + clear stub note.
	_ = data
	var peek struct {
		Format      int    `json:"format"`
		CipherCombo string `json:"cipherCombo"`
	}
	// Some tooling writes a JSON sidecar; JWT is opaque here.
	_ = json.Unmarshal(data, &peek)

	format := peek.Format
	if format == 0 {
		format = Format8 // product lock; verified once Platforms unlocks JWT
	}
	combo := peek.CipherCombo
	if combo == "" {
		combo = "SIV_GCM" // format-8 default; confirm via cryptolib
	}

	// Root dirId is empty string; ciphertext prefix needs encryptDirId hash.
	// Placeholder empty until crypto lands — unlock still prints format/combo.
	return Meta{
		Format:           format,
		CipherCombo:      combo,
		RootCipherPrefix: "(pending cryptolib encryptDirId)",
	}, nil
}
