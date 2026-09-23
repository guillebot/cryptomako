package vault

import (
	"crypto/aes"
	"encoding/json"
	"io"

	aesWrap "github.com/NickBall/go-aes-key-wrap"
	"golang.org/x/crypto/scrypt"
)

const masterKeySize = 32

// Masterkey holds the unwrapped Cryptomator AES-SIV / content keys.
type Masterkey struct {
	EncKey []byte
	MacKey []byte
}

type masterkeyFile struct {
	Version          int    `json:"version"`
	ScryptSalt       []byte `json:"scryptSalt"`
	ScryptCostParam  int    `json:"scryptCostParam"`
	ScryptBlockSize  int    `json:"scryptBlockSize"`
	PrimaryMasterKey []byte `json:"primaryMasterKey"`
	HmacMasterKey    []byte `json:"hmacMasterKey"`
	VersionMac       []byte `json:"versionMac"`
}

// UnlockMasterkey unwraps masterkey.cryptomator with the vault passphrase.
// Failures are opaque (wrong password / corrupt file look the same).
func UnlockMasterkey(r io.Reader, passphrase string) (Masterkey, error) {
	var f masterkeyFile
	if err := json.NewDecoder(r).Decode(&f); err != nil {
		return Masterkey{}, errUnlockFailed
	}
	if f.ScryptCostParam <= 0 || f.ScryptBlockSize <= 0 || len(f.ScryptSalt) == 0 {
		return Masterkey{}, errUnlockFailed
	}
	kek, err := scrypt.Key([]byte(passphrase), f.ScryptSalt, f.ScryptCostParam, f.ScryptBlockSize, 1, masterKeySize)
	if err != nil {
		return Masterkey{}, errUnlockFailed
	}
	defer wipe(kek)
	block, err := aes.NewCipher(kek)
	if err != nil {
		return Masterkey{}, errUnlockFailed
	}
	encKey, err := aesWrap.Unwrap(block, f.PrimaryMasterKey)
	if err != nil {
		return Masterkey{}, errUnlockFailed
	}
	macKey, err := aesWrap.Unwrap(block, f.HmacMasterKey)
	if err != nil {
		wipe(encKey)
		return Masterkey{}, errUnlockFailed
	}
	if len(encKey) != masterKeySize || len(macKey) != masterKeySize {
		wipe(encKey)
		wipe(macKey)
		return Masterkey{}, errUnlockFailed
	}
	return Masterkey{EncKey: encKey, MacKey: macKey}, nil
}

// RawKey is encKey || macKey (JWT HMAC key material).
func (m Masterkey) RawKey() []byte {
	out := make([]byte, 0, len(m.EncKey)+len(m.MacKey))
	out = append(out, m.EncKey...)
	out = append(out, m.MacKey...)
	return out
}

// SivKey is macKey || encKey for AES-SIV (Cryptomator / jacobsa convention).
func (m Masterkey) SivKey() []byte {
	out := make([]byte, 0, len(m.MacKey)+len(m.EncKey))
	out = append(out, m.MacKey...)
	out = append(out, m.EncKey...)
	return out
}

func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
