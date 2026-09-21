# CryptoMako

CryptoMako presents a [Cryptomator](https://cryptomator.org) vault stored on S3 (or S3-compatible storage) as plaintext in a SwiftUI app and, when signed, as a Finder location via File Provider. Licensed under **AGPLv3** (including paid distribution).

Decryption always happens in-process. CryptoMako never mounts ciphertext for Cryptomator/FUSE to sit on top of.

## License

[GNU Affero General Public License v3.0](LICENSE). You may charge for copies or access; recipients retain AGPL rights to corresponding source and to run modified versions. CryptoMako links [`cryptolib-swift`](https://github.com/cryptomator/cryptolib-swift), also AGPLv3 — compatible while CryptoMako stays AGPL.

## Requirements

- macOS 14+
- Swift 5.10+ / Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (the `.xcodeproj` is generated from `project.yml`)
- Docker (optional, for local MinIO)
- An Apple Developer Program membership to run the File Provider extension and App Groups

No AWS SDK: S3 requests are SigV4-signed in-process and sent with an **ephemeral** `URLSession` (no `URLCache` — a stale cached `masterkey.cryptomator` after a vault rewrite would otherwise break unlock). The dependency graph is `cryptolib-swift`, `base32`, and `swift-argument-parser`.

## Build

```bash
cd ~/dev/cryptomako
swift build
swift run cryptomako --help          # CLI product name is lowercase
swift test                           # offline tests, no network
make test
make ci
make security                        # Trivy + Grype

# Local vault, no S3:
swift run cryptomako fixture
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < fixtures/PASSWORD)"
swift run cryptomako ls --local fixtures/vault --path / --recursive

# Signed app + File Provider (needs DEVELOPMENT_TEAM in project.yml):
xcodegen generate
xcodebuild -project CryptoMako.xcodeproj -scheme CryptoMako \
  -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/CryptoMako-*/Build/Products/Debug/CryptoMako.app
```

## App UI (Local vs S3)

The settings form uses a **Local / S3** segmented control:

- **Local** — path to a vault directory that contains `vault.cryptomator`.
- **S3** — endpoint, region, bucket, **vault prefix**, access key, secret key.

The prefix is the folder inside the bucket that holds `vault.cryptomator` (example: `cryptomako-poc/`). The UI shows a live preview of the object key it will fetch (`{bucket}/{prefix}vault.cryptomator`). Empty prefix means bucket root. Non-empty prefixes get a trailing slash on save.

Settings JSON also stores `storageMode` (`local` | `s3`). Legacy configs without it treat a non-empty `localVaultPath` as local.

## Quick path (CLI)

Connection settings live in `~/.config/cryptomako/poc.json` (and the app-group `settings.json`). Never put secrets there:

```json
{
  "storageMode": "s3",
  "endpoint": "https://your-minio-host:9000",
  "region": "us-east-1",
  "bucket": "your-bucket",
  "prefix": "cryptomako-poc/",
  "accessKey": "your-access-key"
}
```

Prefer **HTTPS**. The sandboxed app and File Provider are ATS-constrained; plain `http://` endpoints fail in the `.app` even when the CLI works.

Secrets come from the environment (CLI) or Keychain (app):

```bash
export CRYPTOMAKO_SECRET_KEY='...'
export CRYPTOMAKO_PASSWORD='your-vault-password'

swift run cryptomako unlock --prefix cryptomako-poc/
swift run cryptomako ls --prefix cryptomako-poc/ --path / -R
swift run cryptomako cat --prefix cryptomako-poc/ /hello.txt
```

Any flag overrides the config file.

`./scripts/minio-up.sh` starts a throwaway local MinIO if you do not have a remote bucket.

## File Provider mount

After Unlock + **Mount in Finder** in a signed Debug/Release `.app`, the vault appears under Finder → Locations and on disk at:

```text
~/Library/CloudStorage/CryptoMako-CryptoMako
```

(Exact folder name is `CryptoMako-<displayName>`.) See [docs/30-m2-file-provider.md](docs/30-m2-file-provider.md).

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/00-product.md](docs/00-product.md) | Thesis, naming, out of scope |
| [docs/10-m0-fixture.md](docs/10-m0-fixture.md) | MinIO + Cryptomator fixture |
| [docs/20-m1-cli.md](docs/20-m1-cli.md) | CLI contract |
| [docs/30-m2-file-provider.md](docs/30-m2-file-provider.md) | Finder extension |
| [docs/40-m3-writes.md](docs/40-m3-writes.md) | Writes + Cryptomator health check |
| [docs/50-security.md](docs/50-security.md) | Secrets, logging, threat model |
| [docs/architecture/overview.md](docs/architecture/overview.md) | Modules, unlock, listing, item ids |
| [BREAK_GLASS.md](BREAK_GLASS.md) | Emergency wipe |

## Identifiers

| Item | Value |
|------|--------|
| Bundle ID | `net.gschimmel.cryptomako` |
| Extension | `net.gschimmel.cryptomako.FileProvider` |
| App Group (runtime) | `{TEAM_ID}.group.net.gschimmel.cryptomako` (e.g. `H4K6YW7MQM.group…`) |
| Keychain service | `net.gschimmel.cryptomako` |
