package vault

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/jacobsa/crypto/siv"
	"golang.org/x/text/unicode/norm"
)

const (
	gcmNonceSize       = 12
	gcmTagSize         = 16
	headerPayloadSize  = 40 // 8 reserved + 32 content key
	headerSize         = gcmNonceSize + headerPayloadSize + gcmTagSize // 68
	chunkClearSize     = 32 * 1024
	chunkOverhead      = gcmNonceSize + gcmTagSize
	maxChunkCipherSize = chunkClearSize + chunkOverhead
)

// Cryptor implements Cryptomator format-8 SIV_GCM name/dir/content crypto.
type Cryptor struct {
	mk Masterkey
}

func newCryptor(mk Masterkey) *Cryptor {
	return &Cryptor{mk: mk}
}

func (c *Cryptor) close() {
	wipe(c.mk.EncKey)
	wipe(c.mk.MacKey)
}

// EncryptDirIDHash returns the base32(sha1(siv(dirId))) string used under d/.
func (c *Cryptor) EncryptDirIDHash(dirID string) (string, error) {
	enc, err := siv.Encrypt(nil, c.mk.SivKey(), []byte(dirID), nil)
	if err != nil {
		return "", errCorrupt
	}
	sum := sha1.Sum(enc)
	// Exactly 32 chars for 20-byte SHA-1; strip any padding for safety.
	return strings.TrimRight(base32.StdEncoding.EncodeToString(sum[:]), "="), nil
}

// DecryptFileName decrypts a base64url ciphertext name (no .c9r suffix).
func (c *Cryptor) DecryptFileName(cipherBare, dirID string) (string, error) {
	raw, err := base64.URLEncoding.DecodeString(padBase64(cipherBare))
	if err != nil {
		// Some vaults omit padding; try RawURLEncoding.
		raw, err = base64.RawURLEncoding.DecodeString(cipherBare)
		if err != nil {
			return "", errCorrupt
		}
	}
	clear, err := siv.Decrypt(c.mk.SivKey(), raw, [][]byte{[]byte(dirID)})
	if err != nil {
		return "", errCorrupt
	}
	if !utf8.Valid(clear) {
		return "", errCorrupt
	}
	return string(clear), nil
}

// EncryptFileName returns ciphertextBare + ".c9r" (NFC-normalized cleartext).
func (c *Cryptor) EncryptFileName(clearName, dirID string) (string, error) {
	nfc := norm.NFC.String(clearName)
	enc, err := siv.Encrypt(nil, c.mk.SivKey(), []byte(nfc), [][]byte{[]byte(dirID)})
	if err != nil {
		return "", errCorrupt
	}
	return base64.URLEncoding.EncodeToString(enc) + ".c9r", nil
}

// ShortenedName is SHA-1(base64url) of the full encrypted name including .c9r.
func ShortenedName(ciphertextFileName string) string {
	sum := sha1.Sum([]byte(ciphertextFileName))
	return base64URLEncodeNoPad(sum[:]) + ".c9s"
}

func padBase64(s string) string {
	switch len(s) % 4 {
	case 2:
		return s + "=="
	case 3:
		return s + "="
	default:
		return s
	}
}

// DecryptContent decrypts a full SIV_GCM ciphertext file into cleartext.
func (c *Cryptor) DecryptContent(ciphertext []byte) ([]byte, error) {
	if len(ciphertext) < headerSize {
		return nil, errCorrupt
	}
	headerNonce := ciphertext[:gcmNonceSize]
	headerCT := ciphertext[gcmNonceSize : headerSize]

	block, err := aes.NewCipher(c.mk.EncKey)
	if err != nil {
		return nil, errCorrupt
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, errCorrupt
	}
	// headerCT is ciphertext||tag (40+16) with no separate AAD for header
	payload, err := gcm.Open(nil, headerNonce, headerCT, nil)
	if err != nil {
		return nil, errCorrupt
	}
	if len(payload) != headerPayloadSize {
		return nil, errCorrupt
	}
	contentKey := payload[8:]

	contentBlock, err := aes.NewCipher(contentKey)
	if err != nil {
		return nil, errCorrupt
	}
	contentGCM, err := cipher.NewGCM(contentBlock)
	if err != nil {
		return nil, errCorrupt
	}

	rest := ciphertext[headerSize:]
	if len(rest) == 0 {
		return []byte{}, nil
	}
	var clear []byte
	var chunkIdx uint64
	for len(rest) > 0 {
		if len(rest) < chunkOverhead {
			return nil, errCorrupt
		}
		// Prefer full chunk; otherwise take the remainder as the last chunk.
		n := maxChunkCipherSize
		if len(rest) < n {
			n = len(rest)
		} else if len(rest) > n && len(rest)-n < chunkOverhead {
			// Would leave a too-small remainder — should not happen on valid files.
			return nil, errCorrupt
		}
		chunk := rest[:n]
		rest = rest[n:]
		chunkNonce := chunk[:gcmNonceSize]
		chunkBody := chunk[gcmNonceSize:] // ciphertext||tag

		aad := make([]byte, 8+gcmNonceSize)
		binary.BigEndian.PutUint64(aad[:8], chunkIdx)
		copy(aad[8:], headerNonce)

		pt, err := contentGCM.Open(nil, chunkNonce, chunkBody, aad)
		if err != nil {
			return nil, errCorrupt
		}
		clear = append(clear, pt...)
		chunkIdx++
	}
	return clear, nil
}

// DecryptContentReader decrypts from an io.ReaderAt / full buffer helper.
func (c *Cryptor) DecryptContentFrom(r io.Reader) ([]byte, error) {
	all, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return c.DecryptContent(all)
}


// EncryptContent encrypts cleartext to SIV_GCM ciphertext (header + chunks).
func (c *Cryptor) EncryptContent(clear []byte) ([]byte, error) {
	headerNonce := make([]byte, gcmNonceSize)
	if _, err := rand.Read(headerNonce); err != nil {
		return nil, err
	}
	contentKey := make([]byte, 32)
	if _, err := rand.Read(contentKey); err != nil {
		return nil, err
	}
	payload := make([]byte, headerPayloadSize)
	for i := 0; i < 8; i++ {
		payload[i] = 0xFF
	}
	copy(payload[8:], contentKey)

	block, err := aes.NewCipher(c.mk.EncKey)
	if err != nil {
		return nil, errCorrupt
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, errCorrupt
	}
	headerCT := gcm.Seal(nil, headerNonce, payload, nil) // ct||tag (56)

	out := make([]byte, 0, headerSize+len(clear)+(len(clear)/chunkClearSize+1)*chunkOverhead)
	out = append(out, headerNonce...)
	out = append(out, headerCT...)

	contentBlock, err := aes.NewCipher(contentKey)
	if err != nil {
		return nil, errCorrupt
	}
	contentGCM, err := cipher.NewGCM(contentBlock)
	if err != nil {
		return nil, errCorrupt
	}

	var chunkIdx uint64
	for off := 0; off < len(clear); {
		end := off + chunkClearSize
		if end > len(clear) {
			end = len(clear)
		}
		chunkNonce := make([]byte, gcmNonceSize)
		if _, err := rand.Read(chunkNonce); err != nil {
			return nil, err
		}
		aad := make([]byte, 8+gcmNonceSize)
		binary.BigEndian.PutUint64(aad[:8], chunkIdx)
		copy(aad[8:], headerNonce)
		sealed := contentGCM.Seal(nil, chunkNonce, clear[off:end], aad)
		out = append(out, chunkNonce...)
		out = append(out, sealed...)
		chunkIdx++
		off = end
	}
	return out, nil
}
