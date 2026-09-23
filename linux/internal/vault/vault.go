// Package vault defines Cryptomator format-8 unlock/layout interfaces.
//
// Crypto is intentionally stubbed. Real decrypt/list/open will golden-test
// against repo fixtures/ once Platforms locks cryptolib for Linux.
// Do not invent fake crypto that claims to work.
package vault

import (
	"fmt"
	"io"

	"github.com/guillebot/cryptomako/linux/internal/config"
)

// Format8 is the locked Cryptomator vault format version for CryptoMako.
const Format8 = 8

// Entry is a cleartext directory listing row.
type Entry struct {
	Name  string
	IsDir bool
}

// Session is an unlocked vault handle (cleartext UX; ciphertext stays remote/on disk).
type Session struct {
	Format           int
	CipherCombo      string
	RootCipherPrefix string // e.g. d/XX/YYY…/ under the vault prefix
	cfg              config.Config
}

// Unlock opens a format-8 vault from local disk or S3 config.
//
// TODO(platforms): replace stub with cryptolib unlock + JWT masterkey unwrap.
// Golden tests will live against ../../fixtures/ once Platforms locks the lib.
func Unlock(cfg config.Config) (*Session, error) {
	if cfg.Passphrase == "" {
		return nil, fmt.Errorf("vault: missing passphrase")
	}
	if cfg.IsLocal() {
		meta, err := readLocalVaultMeta(cfg.LocalRoot)
		if err != nil {
			return nil, err
		}
		return &Session{
			Format:           meta.Format,
			CipherCombo:      meta.CipherCombo,
			RootCipherPrefix: meta.RootCipherPrefix,
			cfg:              cfg,
		}, nil
	}
	// Remote unlock needs S3 GetObject of vault.cryptomator — crypto still stubbed.
	return nil, fmt.Errorf("vault: S3 unlock not implemented yet (crypto stubbed pending Platforms fixtures); use --local for layout checks")
}

// Close releases session resources (no-op while crypto is stubbed).
func (s *Session) Close() error { return nil }

// List returns cleartext names under path.
//
// TODO(platforms): decrypt dir.c9r / name map via cryptolib; golden vs fixtures/expected-ls.txt.
func (s *Session) List(path string, recursive bool) ([]Entry, error) {
	_ = recursive
	return nil, fmt.Errorf("vault: List(%q) not implemented — crypto stubbed pending Platforms fixtures/ golden tests", path)
}

// Open decrypts a cleartext path and returns a plaintext reader.
//
// TODO(platforms): Cryptor.decryptContent; golden vs fixtures vault bytes.
// Never mount ciphertext; cleartext only through this API / future FUSE.
func (s *Session) Open(cleartextPath string) (io.ReadCloser, error) {
	return nil, fmt.Errorf("vault: Open(%q) not implemented — crypto stubbed pending Platforms fixtures/ golden tests", cleartextPath)
}
