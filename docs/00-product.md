# Product

CryptoMako is a macOS companion that presents a Cryptomator vault stored on S3 as plaintext. It is not a Cryptomator fork.

## Thesis

Decrypt inside CryptoMako (CLI now, File Provider later). Never expose ciphertext as a folder for Cryptomator desktop / FUSE-T / macFUSE to mount. Nested File Provider + FUSE is a known Finder deadlock.

## Naming

| Item | Value |
|------|--------|
| Product | CryptoMako |
| CLI | `cryptomako` |
| Repo | `~/dev/cryptomako` |
| Bundle ID (M2) | `net.gschimmel.cryptomako` |
| Extension | `net.gschimmel.cryptomako.FileProvider` |
| App Group | `group.net.gschimmel.cryptomako` |
| License | AGPLv3 |

## Locked rules

- Vault format **8** only; password unlock; one vault; one Mac.
- **Host app GUI** (SwiftUI): view/edit connection config, unlock, show status and a listing. Secrets stay in the window / Keychain, never in `poc.json`. The File Provider (M2) is Finder; this window is how you configure and watch the vault.
- Interop: anything written (M3) must open in stock Cryptomator and pass Directory Health Check with zero warnings.
- Secrets never on argv: `CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY` (Keychain from M2).
- DirId is the stable item id. Folder rename is O(1) (rewrite `dir.c9r`), not a prefix copy.
- Every content encrypt uses a fresh header and nonces. No ciphertext reuse on save.
- Manual refresh only in the PoC. No S3 changelog polling.

## Out of scope (PoC)

Cryptomator Hub, keyfiles, vault formats 6/7, multi-vault, incremental remote sync, Spotlight claims, Mac App Store, byte-range streaming, file locking, `cloud-access-swift` as a dependency.
