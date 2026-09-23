# CryptoMako Linux

Linux port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over **HTTPS**, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `linux/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault once Platforms locks cryptolib.

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

# Local vault directory (layout / unlock stub — crypto pending Platforms)
./cryptomako unlock --local ../fixtures/vault

# After cryptolib lands:
# ./cryptomako ls --local ../fixtures/vault --path / -R
# ./cryptomako cat --local ../fixtures/vault /hello.txt
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
| `internal/vault` | Format-8 unlock/layout interfaces — **crypto stubbed** |
| `internal/config` | XDG config + env secrets |

## Crypto status

Decrypt / cleartext `ls` / `cat` are **stubbed** until Platforms locks cryptolib and golden tests against `fixtures/`. Do not treat unlock metadata as proof of interoperability yet. Wrong-password behaviour and fixture acceptance land with real crypto.

## License

AGPL-3.0 (same as the parent repo).
