# CryptoMako Linux

Linux port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over **HTTPS**, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `linux/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault (format 8 / SIV_GCM).

## Surfaces (roadmap)

| Surface | Role |
|---------|------|
| **CLI** (`unlock` / `ls` / `cat`) | First milestone — this folder |
| **libfuse3 FUSE** | Cleartext mount for tools; never mount ciphertext |
| **Backup Sync** | Large trees: walk → encrypt → remote put. Fail-closed |

## Product locks

- Cryptomator **format 8**
- **HTTPS only** (SigV4; no AWS SDK)
- Remote **put/delete fail closed**
- Cleartext local UX; **never mount ciphertext**

## Requirements

- Go **1.22+**
- Vault password in `CRYPTOMAKO_PASSWORD` (never argv; never JSON)
- S3 secret in `CRYPTOMAKO_SECRET_KEY` (never JSON)

## Build

```bash
cd linux
go test ./...
go build -o cryptomako .
```

## Run

```bash
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < ../fixtures/PASSWORD)"

# Local format-8 SIV_GCM vault (golden vs fixtures/)
./cryptomako unlock --local ../fixtures/vault
# format: 8
# cipherCombo: SIV_GCM
# rootPrefix: d/FQ/QG7OOSQNZM6BJDZAIENVAOACYROMHW/

./cryptomako ls --local ../fixtures/vault --path / --recursive | diff -u ../fixtures/expected-ls.txt -
./cryptomako cat --local ../fixtures/vault /hello.txt
# → hello cryptomako
```

Remote (S3) needs non-secret config plus the secret env:

```bash
# ~/.config/cryptomako/config.json  (XDG; no secrets)
# { "endpoint":"https://minio.example","region":"us-east-1","bucket":"b","prefix":"vault/","accessKeyId":"AK…" }
export CRYPTOMAKO_SECRET_KEY=…
./cryptomako unlock --endpoint https://minio.example --bucket b --prefix vault/ --access-key AK…
```

## Config (non-secrets only)

Default path: `$XDG_CONFIG_HOME/cryptomako/config.json` or `~/.config/cryptomako/config.json`.

| Field | Meaning |
|-------|---------|
| `endpoint` | S3 API URL (HTTPS, no bucket in path) |
| `region` | Region string (MinIO: `us-east-1`) |
| `bucket` | Bucket name |
| `prefix` | Vault prefix (`vault.cryptomator` lives here) |
| `accessKeyId` | Access key id |

**Never** store password or secret key in JSON.

## Packages

| Package | Role |
|---------|------|
| `internal/s3` | SigV4 HTTPS client: GetObject, PutObject, DeleteObject, ListObjectsV2 |
| `internal/vault` | Format-8 **SIV_GCM** unlock / ls / cat (local FS + S3 SigV4) |
| `internal/config` | XDG config + env secrets |

## Crypto status

Local **format 8 / SIV_GCM** unlock, cleartext `ls`, and `cat` are implemented in `internal/vault` (scrypt + AES-KW masterkey, JWT verify with enc||mac, AES-SIV names/dirIds, AES-GCM content, `.c9s` name shortening). Golden tests run against `../fixtures/` when `PASSWORD` is present.

Local and S3 unlock share the same cryptor. Remote put/delete remain fail-closed (non-2xx → error) in the S3 client. CLI reads (`unlock`/`ls`/`cat`) never call put/delete.

## License

AGPL-3.0 (same as the parent repo).
