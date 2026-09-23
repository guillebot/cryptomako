package vault

import "errors"

// Opaque unlock failure — never include key material or crypto internals.
var errUnlockFailed = errors.New("vault: unlock failed")

var (
	errUnsupportedFormat = errors.New("vault: unsupported format")
	errUnsupportedCipher = errors.New("vault: unsupported cipherCombo")
	errNotFound          = errors.New("vault: path not found")
	errNotAFile          = errors.New("vault: not a file")
	errCorrupt           = errors.New("vault: corrupt ciphertext")
)
