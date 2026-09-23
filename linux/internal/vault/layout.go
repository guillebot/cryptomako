package vault

import "strings"

// CipherDirPrefix builds the Cryptomator d/<2>/<rest>/ layout path segment.
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

func (c *Cryptor) dirPrefix(dirID string) (string, error) {
	hash, err := c.EncryptDirIDHash(dirID)
	if err != nil {
		return "", err
	}
	return CipherDirPrefix("", hash), nil
}
