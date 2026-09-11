# CryptoMako

CryptoMako presents a [Cryptomator](https://cryptomator.org) vault stored on S3 (or S3-compatible storage) as plaintext. Licensed under **AGPLv3** (including paid distribution).

The PoC is a CLI (`cryptomako`) plus a SwiftUI window (`CryptoMakoApp`) for config and status. A File Provider extension comes later (see `docs/30-m2-file-provider.md`). Decryption always happens in-process. CryptoMako never mounts ciphertext for Cryptomator/FUSE to sit on top of.

## License

[GNU Affero General Public License v3.0](LICENSE). You may charge for copies or access; recipients retain AGPL rights to corresponding source and to run modified versions. CryptoMako links [`cryptolib-swift`](https://github.com/cryptomator/cryptolib-swift), also AGPLv3 — compatible while CryptoMako stays AGPL.

## Requirements

- macOS 14+
- Swift 5.10+ / Xcode 16+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (M2 only; the `.xcodeproj` is generated from `project.yml`)
- Docker (optional, for local MinIO)
- An Apple Developer Program membership to *run* the File Provider extension

No AWS SDK: S3 requests are SigV4-signed in-process and sent with `URLSession`.
The full dependency graph is `cryptolib-swift`, `base32`, and
`swift-argument-parser`.

## Build

```bash
cd ~/dev/cryptomako
swift build
swift run cryptomako --help
swift run CryptoMakoApp   # config + status window
swift test                # offline tests, no network, no Apple ID
make test                 # same
make ci                   # release build + tests
make security             # Trivy + Grype (brew install trivy grype)

# Local vault, no S3:
cryptomako fixture
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < fixtures/PASSWORD)"
swift run cryptomako ls --local fixtures/vault --path / --recursive
swift run CryptoMakoApp

# M2: generate and compile the app + File Provider extension
xcodegen generate
xcodebuild -project CryptoMako.xcodeproj -scheme CryptoMako \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Quick path

Connection settings live in `~/.config/cryptomako/poc.json` (never secrets):

```json
{
  "endpoint": "http://your-minio-host:9000",
  "region": "us-east-1",
  "bucket": "your-bucket",
  "accessKey": "your-access-key"
}
```

Secrets come from the environment (`CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY`), never from argv or the config file:

```bash
export CRYPTOMAKO_SECRET_KEY='...'
export CRYPTOMAKO_PASSWORD='your-vault-password'

swift run cryptomako unlock --prefix cryptomako-poc/
swift run cryptomako ls --prefix cryptomako-poc/ --path / -R
swift run cryptomako cat --prefix cryptomako-poc/ /hello.txt
```

Any flag overrides the config file, so a second vault or endpoint needs no config edit:

```bash
swift run cryptomako unlock \
  --endpoint http://127.0.0.1:9000 \
  --bucket cryptomako-poc \
  --prefix family/ \
  --access-key cryptomako
```

`./scripts/minio-up.sh` starts a throwaway local MinIO if you do not have a remote bucket. It is a convenience for the fixture, not a requirement.

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/00-product.md](docs/00-product.md) | Thesis, naming, out of scope |
| [docs/10-m0-fixture.md](docs/10-m0-fixture.md) | MinIO + Cryptomator fixture |
| [docs/20-m1-cli.md](docs/20-m1-cli.md) | CLI contract |
| [docs/30-m2-file-provider.md](docs/30-m2-file-provider.md) | Finder extension (later) |
| [docs/40-m3-writes.md](docs/40-m3-writes.md) | Writes + Cryptomator health check |
| [docs/50-security.md](docs/50-security.md) | Secrets, logging, threat model |
| [docs/architecture/overview.md](docs/architecture/overview.md) | Modules, unlock, listing, item ids |
| [BREAK_GLASS.md](BREAK_GLASS.md) | Emergency wipe |

## Identifiers (M2)

| Item | Value |
|------|--------|
| Bundle ID | `net.gschimmel.cryptomako` |
| Extension | `net.gschimmel.cryptomako.FileProvider` |
| App Group | `group.net.gschimmel.cryptomako` |
