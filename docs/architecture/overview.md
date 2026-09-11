# Architecture

## Modules

```
CryptoMakoCLI  →  CryptoMakoVault  →  cryptolib-swift
                       ↓
                 CryptoMakoS3  →  Soto S3
```

`cloud-access-swift` is a reference implementation (iOS), not a dependency.

## Unlock

1. `GetObject` `{prefix}vault.cryptomator` → JWT.
2. Decode JWT without verifying. Read `kid` (expect `masterkeyfile:masterkey.cryptomator`), `format`, `cipherCombo`, `shorteningThreshold`.
3. Reject if `format != 8`.
4. `GetObject` `{prefix}masterkey.cryptomator`.
5. `MasterkeyFile.withContentFromData` → `unlock(passphrase:)`.
6. Verify JWT HMAC using `Masterkey.rawKey`. Fail closed.
7. `Cryptor(masterkey:scheme:)` from `cipherCombo` (`SIV_GCM` → `.sivGcm`, `SIV_CTRMAC` → `.sivCtrMac`).

## Directory layout (format 8)

```
hash = cryptor.encryptDirId(Data(dirId.utf8))   // Base32 SHA-1 of AES-SIV(dirId)
s3Key = prefix + "d/" + hash[0..<2] + "/" + hash[2...] + "/"
```

Root `dirId` is the empty string.

| Ciphertext | Meaning |
|------------|---------|
| `<enc>.c9r` object | regular file |
| `<enc>.c9r/` + `dir.c9r` | subdirectory; body is UTF-8 child dirId |
| `<enc>.c9r/` + `symlink.c9r` | symlink (list, do not follow) |
| `<enc>.c9s/` + `name.c9s` + `contents.c9r` | shortened file |
| `<enc>.c9s/` + `name.c9s` + `dir.c9r` | shortened directory |

`enc` is `encryptFileName(cleartext, dirId: parent)` then `+ ".c9r"`. If that name is longer than `shorteningThreshold` (typically 220), the node is stored under `base64url(sha1(enc + ".c9r")) + ".c9s"`.

`vault.cryptomator` and `masterkey.cryptomator` are not part of the cleartext tree.

## Item identifiers (M2)

- Directory: `d:<dirId>` (`d:` for root)
- File: `f:<parentDirId>/<cipherName>`

DirIds do not change when a folder is renamed or moved.
