# CryptoMako

CryptoMako presents a [Cryptomator](https://cryptomator.org) vault stored on S3 (or S3-compatible storage) as plaintext. Licensed under **AGPLv3** (including paid distribution).

The PoC is a CLI (`cryptomako`) that unlocks a format-8 vault, lists the cleartext tree, and decrypts files. A macOS File Provider extension comes later (see `docs/30-m2-file-provider.md`). Decryption always happens in-process. CryptoMako never mounts ciphertext for Cryptomator/FUSE to sit on top of.

## License

GNU Affero General Public License v3.0. CryptoMako links [`cryptolib-swift`](https://github.com/cryptomator/cryptolib-swift), which is AGPLv3.

## Requirements

- macOS 14+
- Swift 5.10+ / Xcode 16+
- Docker (optional, for local MinIO)

## Build

```bash
cd ~/dev/cryptomako
swift build
swift run cryptomako --help
```

## Quick path (after you have a vault on MinIO)

```bash
./scripts/minio-up.sh
# Create a Cryptomator vault locally, copy ciphertext into bucket cryptomako-poc prefix family/
# See fixtures/README.md

export CRYPTOMAKO_SECRET_KEY=cryptomako-minio-dev
export CRYPTOMAKO_PASSWORD='your-vault-password'

swift run cryptomako unlock \
  --endpoint http://127.0.0.1:9000 \
  --region us-east-1 \
  --bucket cryptomako-poc \
  --prefix family/ \
  --access-key cryptomako

swift run cryptomako ls --path / -R
swift run cryptomako cat /hello.txt
```

Secrets are read from the environment (`CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY`), never from argv.

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
