package vault

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"hash"
	"strings"
)

type vaultJWTHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
	Typ string `json:"typ"`
}

type vaultJWTPayload struct {
	Format              int    `json:"format"`
	ShorteningThreshold int    `json:"shorteningThreshold"`
	CipherCombo         string `json:"cipherCombo"`
	JTI                 string `json:"jti"`
}

func decodeUnverifiedJWT(token string) (vaultJWTHeader, vaultJWTPayload, string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return vaultJWTHeader{}, vaultJWTPayload{}, "", errUnlockFailed
	}
	hb, err := base64URLDecode(parts[0])
	if err != nil {
		return vaultJWTHeader{}, vaultJWTPayload{}, "", errUnlockFailed
	}
	pb, err := base64URLDecode(parts[1])
	if err != nil {
		return vaultJWTHeader{}, vaultJWTPayload{}, "", errUnlockFailed
	}
	var h vaultJWTHeader
	var p vaultJWTPayload
	if err := json.Unmarshal(hb, &h); err != nil {
		return vaultJWTHeader{}, vaultJWTPayload{}, "", errUnlockFailed
	}
	if err := json.Unmarshal(pb, &p); err != nil {
		return vaultJWTHeader{}, vaultJWTPayload{}, "", errUnlockFailed
	}
	return h, p, parts[0] + "." + parts[1], nil
}

func verifyVaultJWT(token string, rawKey []byte) (vaultJWTPayload, error) {
	h, p, signingInput, err := decodeUnverifiedJWT(token)
	if err != nil {
		return vaultJWTPayload{}, err
	}
	parts := strings.Split(token, ".")
	sig, err := base64URLDecode(parts[2])
	if err != nil {
		return vaultJWTPayload{}, errUnlockFailed
	}
	var mac hash.Hash
	switch strings.ToUpper(h.Alg) {
	case "HS256":
		mac = hmac.New(sha256.New, rawKey)
	case "HS384":
		mac = hmac.New(sha512.New384, rawKey)
	case "HS512":
		mac = hmac.New(sha512.New, rawKey)
	default:
		return vaultJWTPayload{}, errUnlockFailed
	}
	mac.Write([]byte(signingInput))
	if !hmac.Equal(mac.Sum(nil), sig) {
		return vaultJWTPayload{}, errUnlockFailed
	}
	return p, nil
}

func base64URLDecode(s string) ([]byte, error) {
	s = strings.ReplaceAll(s, "-", "+")
	s = strings.ReplaceAll(s, "_", "/")
	switch len(s) % 4 {
	case 2:
		s += "=="
	case 3:
		s += "="
	}
	return base64.StdEncoding.DecodeString(s)
}

func base64URLEncodeNoPad(b []byte) string {
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "=")
}
