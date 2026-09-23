# CryptoMako Linux

Linux port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over **HTTPS**, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `linux/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault (format 8 / SIV_GCM).

## Surfaces (roadmap)

| Surface | Role |
|---------|------|
| **CLI** (`unlock` / `ls` / `cat` / `fixture`) | Unlock/browse; `fixture` builds a minimal format-8 vault for CI |
| **FUSE** (`mount`) | Cleartext mount (`go-fuse` / `/dev/fuse`); default **ro**, optional **`--rw`** with fail-closed remote put/delete |
| **Backup Sync** (`sync`) | Walk cleartext → encrypt → put (local or S3). Fail-closed |

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

# Non-recursive: basenames only (Mac parity: hello.txt, bin/)
./cryptomako ls --local ../fixtures/vault
# Recursive: absolute cleartext paths (matches fixtures/expected-ls.txt)
./cryptomako ls --local ../fixtures/vault --path / --recursive | diff -u ../fixtures/expected-ls.txt -
./cryptomako cat --local ../fixtures/vault /hello.txt
# → hello cryptomako

# FUSE cleartext mount (Linux; default read-only)
mkdir -p /tmp/cryptomako-mnt
./cryptomako mount --local ../fixtures/vault --mountpoint /tmp/cryptomako-mnt
# cat /tmp/cryptomako-mnt/hello.txt

# Writable FUSE (fail-closed: create/write/rename/unlink/mkdir → PutObject/DeleteObject)
./cryptomako mount --local /path/to/vault --mountpoint /tmp/cryptomako-mnt --rw
# echo hi > /tmp/cryptomako-mnt/new.txt   # encrypts + puts; errors if store put fails

# Backup sync (encrypt local tree into vault)
./cryptomako sync --local ../fixtures/vault --source ~/Documents/tree --dest /
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

## Config keys (Platforms alignment)

JSON (`~/.config/cryptomako/config.json`) — **no secrets**:

| Key | Notes |
|-----|--------|
| `endpoint` | HTTPS S3 API URL |
| `region` | e.g. `us-east-1` |
| `bucket` | Bucket name |
| `prefix` | Vault prefix (`vault/` style) |
| `accessKeyId` | Access key id |

Env secrets: `CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY`.

Proposed to Platforms before inventing new keys. Current set matches macOS `ConnectionConfigLoader` / docs/10-m0-fixture.md.

## Docker

Build from the `linux/` context (Dockerfile installs `fuse3`):

```bash
cd linux
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < ../fixtures/PASSWORD)"
docker build -t cryptomako .
```

CLI-only (works on Docker Desktop macOS):

```bash
docker run --rm -e CRYPTOMAKO_PASSWORD \
  -v "$PWD/../fixtures/vault:/vault:ro" \
  cryptomako unlock --local /vault

docker run --rm -e CRYPTOMAKO_PASSWORD \
  -v "$PWD/../fixtures/vault:/vault:ro" \
  cryptomako ls --local /vault --recursive
```

### FUSE smoke (needs `/dev/fuse`)

Exact flags for a real Linux Docker host (or CI) with FUSE passthrough:

```bash
docker run --rm -it \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --security-opt apparmor:unconfined \
  -e CRYPTOMAKO_PASSWORD \
  -v "$PWD/../fixtures/vault:/vault:ro" \
  --entrypoint sh \
  cryptomako \
  -c 'mkdir -p /mnt/cm
     cryptomako mount --local /vault --mountpoint /mnt/cm &
     i=0; while [ ! -f /mnt/cm/hello.txt ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
     cat /mnt/cm/hello.txt
     fusermount3 -u /mnt/cm'
```

Or use the host script (cleartext `hello cryptomako`, clean unmount). Creates a
minimal vault via `cryptomako fixture` when `fixtures/` is absent (CI):

```bash
./scripts/fuse-smoke.sh
# Writable smoke (create/write/rename/unlink/mkdir through the mount):
CRYPTOMAKO_FUSE_RW=1 ./scripts/fuse-smoke.sh
```

**Host macOS** has no `/dev/fuse`, so `./scripts/fuse-smoke.sh` exits 2 on the Mac host itself.

**Docker Desktop (macOS):** with `--device /dev/fuse --cap-add SYS_ADMIN` the FUSE smoke **can** succeed (verified: cleartext `hello cryptomako` + clean `fusermount3 -u`). If your Docker engine cannot expose `/dev/fuse`, use Linux CI/hosts with the same flags or `./scripts/fuse-smoke.sh`. Unit tests under `internal/fusefs` construct the FUSE root without a live mount.


## Install (deb sketch)

No new VaultSettings keys; secrets stay env-only; S3 is path-style (locked with Platforms).

```bash
cd linux
go build -o cryptomako .
sudo install -m 0755 cryptomako /usr/local/bin/cryptomako
sudo apt-get install -y fuse3   # or fuse3 from your distro
```

Optional thin deb layout (manual / `nfpm` later): binary → `/usr/bin/cryptomako`,
depends on `fuse3`, no config package (XDG `~/.config/cryptomako/config.json` is
user-owned; never ship secrets). See `packaging/README.md`.

## License

AGPL-3.0 (same as the parent repo).
