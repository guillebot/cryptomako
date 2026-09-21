# Product

CryptoMako is a macOS companion that presents a Cryptomator vault stored on S3 as plaintext. It is not a Cryptomator fork.

## Thesis

Decrypt inside CryptoMako (CLI, SwiftUI app, File Provider). Never expose ciphertext as a folder for Cryptomator desktop / FUSE-T / macFUSE to mount. Nested File Provider + FUSE is a known Finder deadlock.

## Naming

| Item | Value |
|------|--------|
| Product | CryptoMako |
| CLI | `cryptomako` |
| App | `CryptoMako` |
| Repo | `~/dev/cryptomako` / `github.com/guillebot/cryptomako` |
| Bundle ID | `net.gschimmel.cryptomako` |
| Extension | `net.gschimmel.cryptomako.FileProvider` |
| App Group | `{TEAM_ID}.group.net.gschimmel.cryptomako` |
| License | AGPLv3 |

## Locked rules

- Vault format **8** only; password unlock; one vault; one Mac.
- **Host app GUI** (SwiftUI): Local vs S3 storage mode, edit connection config (including an explicit vault **prefix**), unlock, show status and a listing, Mount in Finder. Secrets stay in the window / Keychain, never in `poc.json`.
- Prefer **HTTPS** S3 endpoints for the sandboxed app and extension (ATS).
- Interop: anything written (M3) must open in stock Cryptomator and pass Directory Health Check with zero warnings.
- Secrets never on argv: `CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY` (Keychain in the app).
- DirId is the stable item id. Folder rename is O(1) (rewrite `dir.c9r`), not a prefix copy.
- Every content encrypt uses a fresh header and nonces. No ciphertext reuse on save.
- Manual refresh only in the PoC. No S3 changelog polling.

## Out of scope (PoC)

Cryptomator Hub, keyfiles, vault formats 6/7, multi-vault, incremental remote sync, Spotlight claims, Mac App Store, byte-range streaming, file locking, `cloud-access-swift` as a dependency.
