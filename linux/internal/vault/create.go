package vault

import (
	"crypto/aes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	aesWrap "github.com/NickBall/go-aes-key-wrap"
	"github.com/google/uuid"
	"github.com/guillebot/cryptomako/linux/internal/config"
	"golang.org/x/crypto/scrypt"
)

// CreateFormat8 writes a new empty format-8 SIV_GCM vault under root and returns
// an unlocked session. Used by CI / `cryptomako fixture` when golden fixtures
// are not present. Passphrase must be non-empty.
func CreateFormat8(root, passphrase string) (*Session, error) {
	if passphrase == "" {
		return nil, fmt.Errorf("vault: empty passphrase")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, err
	}
	encKey := make([]byte, masterKeySize)
	macKey := make([]byte, masterKeySize)
	if _, err := rand.Read(encKey); err != nil {
		return nil, err
	}
	if _, err := rand.Read(macKey); err != nil {
		return nil, err
	}
	salt := make([]byte, 8)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	const cost = 32768
	const blockSize = 8
	kek, err := scrypt.Key([]byte(passphrase), salt, cost, blockSize, 1, masterKeySize)
	if err != nil {
		return nil, err
	}
	defer wipe(kek)
	block, err := aes.NewCipher(kek)
	if err != nil {
		return nil, err
	}
	prim, err := aesWrap.Wrap(block, encKey)
	if err != nil {
		return nil, err
	}
	hmacWrapped, err := aesWrap.Wrap(block, macKey)
	if err != nil {
		return nil, err
	}
	mac := hmac.New(sha256.New, macKey)
	mac.Write([]byte("999"))
	versionMac := mac.Sum(nil)

	mkJSON, err := json.Marshal(masterkeyFile{
		Version:          999,
		ScryptSalt:       salt,
		ScryptCostParam:  cost,
		ScryptBlockSize:  blockSize,
		PrimaryMasterKey: prim,
		HmacMasterKey:    hmacWrapped,
		VersionMac:       versionMac,
	})
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(root, "masterkey.cryptomator"), mkJSON, 0o600); err != nil {
		return nil, err
	}

	mk := Masterkey{EncKey: encKey, MacKey: macKey}
	raw := mk.RawKey()
	token, err := signVaultJWT(raw, uuid.NewString())
	wipe(raw)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(root, "vault.cryptomator"), []byte(token), 0o600); err != nil {
		return nil, err
	}

	cryptor := newCryptor(mk)
	rootPrefix, err := cryptor.dirPrefix("")
	if err != nil {
		cryptor.close()
		return nil, err
	}
	diridPath := filepath.Join(root, filepath.FromSlash(rootPrefix), "dirid.c9r")
	if err := os.MkdirAll(filepath.Dir(diridPath), 0o755); err != nil {
		cryptor.close()
		return nil, err
	}
	if err := os.WriteFile(diridPath, []byte{}, 0o600); err != nil {
		cryptor.close()
		return nil, err
	}
	cryptor.close() // Unlock will re-open keys from disk

	return Unlock(config.Config{LocalRoot: root, Passphrase: passphrase})
}

func signVaultJWT(rawKey []byte, jti string) (string, error) {
	headerJSON := []byte(`{"alg":"HS256","kid":"masterkeyfile:masterkey.cryptomator","typ":"JWT"}`)
	payload := vaultJWTPayload{
		Format:              Format8,
		ShorteningThreshold: defaultShorteningThreshold,
		CipherCombo:         "SIV_GCM",
		JTI:                 jti,
	}
	pb, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	h := base64URLEncodeNoPad(headerJSON)
	p := base64URLEncodeNoPad(pb)
	signingInput := h + "." + p
	mac := hmac.New(sha256.New, rawKey)
	mac.Write([]byte(signingInput))
	sig := base64URLEncodeNoPad(mac.Sum(nil))
	return signingInput + "." + sig, nil
}
