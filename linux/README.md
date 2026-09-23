# CryptoMako Linux

<p align="center">
  <img src="../docs/assets/brand/icon.png" alt="CryptoMako" width="128"/>
</p>

Linux port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over **HTTPS**, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `linux/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault (format 8 / SIV_GCM).

## Surfaces (roadmap)

| Surface | Role |
|---------|------|
| **CLI** (`unlock` / `ls` / `cat` / `fixture`) | Unlock/browse; `fixture` builds a minimal format-8 vault for CI |
| **FUSE** (`mount`) | Cleartext mount (`go-fuse` / `/dev/fuse`); default **ro**, optional **`--rw`** with fail-closed remote put/delete |
| **Backup Sync** (`sync` / `sources`) | Walk cleartext → encrypt → put (local or S3). Multi-source via `backup-sources.json`. Fail-closed |

## Product locks

- Cryptomator **format 8**
- **HTTPS only** (SigV4; no AWS SDK)
- Remote **put/delete fail closed**
- Cleartext local UX; **never mount ciphertext**

## Requirements

- Go **1.26+**
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

# Backup sync (encrypt local tree into vault; skips unchanged via backup-sync-state.json)
./cryptomako sync --local ../fixtures/vault --source ~/Documents/tree --dest /

# Or manage macOS-compatible backup sources, then sync all into /Backups/{vaultFolderName}/
./cryptomako sources add ~/Documents/tree
./cryptomako sources add ~/Pictures --vault-folder Photos
./cryptomako sources list
./cryptomako sync --local ../fixtures/vault   # no --source → each entry in backup-sources.json
```

Remote (S3) needs non-secret config plus the secret env:

```bash
# ~/.config/cryptomako/config.json  (XDG; no secrets; field names match docs/10-m0-fixture.md)
# { "endpoint":"https://minio.example","region":"us-east-1","bucket":"b","prefix":"vault/","accessKey":"AK…","pathStyle":true }
export CRYPTOMAKO_SECRET_KEY=…
./cryptomako unlock --endpoint https://minio.example --bucket b --prefix vault/ --access-key AK…
```

## Config (non-secrets only)

Default path: `$XDG_CONFIG_HOME/cryptomako/config.json` or `~/.config/cryptomako/config.json`.
Field names align with macOS `VaultSettings` / `PocConfig` / `docs/10-m0-fixture.md`.

| Field | Meaning |
|-------|---------|
| `endpoint` | S3 API URL (HTTPS, no bucket in path) |
| `region` | Region string (MinIO: `us-east-1`) |
| `bucket` | Bucket name |
| `prefix` | Vault prefix (`vault.cryptomator` lives here) |
| `accessKey` | Access key id (`accessKeyId` accepted as legacy alias) |
| `pathStyle` | Path-style S3 URLs (default `true`; `false` rejected — Platforms lock) |

**Never** store password or secret key in JSON.

### Backup Sync excludes

Same keys as macOS `BackupSyncExcludes` / `backup-sync-excludes.json`:

```json
{
  "excludes": {
    "directoryNames": ["node_modules", ".git"],
    "fileNames": [".DS_Store", "Thumbs.db", "desktop.ini"],
    "fileExtensions": ["pyc", "pyo"]
  }
}
```

Default path: `~/.config/cryptomako/backup-sync-excludes.json`. Missing file → macOS defaults.
Override with `cryptomako sync --excludes /path/to/backup-sync-excludes.json`.

### Backup Sync state (fingerprints)

Same schema as macOS `Sources/CryptoMakoShared/BackupSyncState.swift` (app-group
`backup-sync-state.json`). Linux XDG path (same filename):

`~/.config/cryptomako/backup-sync-state.json` (or `$XDG_CONFIG_HOME/cryptomako/backup-sync-state.json`).

| JSON key | Type | Notes |
|----------|------|-------|
| `files` | object | map of fingerprint entries |
| `files["{vaultFolder}/{relativePath}"].size` | int64 | cleartext byte length |
| `files[…].contentModification` | float64 | seconds since **Apple reference date** 2001-01-01 00:00:00 UTC (`Date.timeIntervalSinceReferenceDate`) |

`vaultFolder` is each source's `vaultFolderName` when syncing from `backup-sources.json`; with `--source` it defaults to the basename of `--source` (macOS `BackupSource` default).
`sync` **skips** put when size+mtime match; updates the fingerprint **only after a successful put** (fail-closed). Index **save is best-effort** (never fails the sync). Override path: `cryptomako sync --sync-state /path/to/backup-sync-state.json`.

### Backup sources (multi-folder Sync)

Same schema as macOS `Sources/CryptoMakoShared/BackupSources.swift` (app-group
`backup-sources.json`). Linux XDG path:

`~/.config/cryptomako/backup-sources.json` (or `$XDG_CONFIG_HOME/cryptomako/backup-sources.json`).

```json
{
  "sources": [
    {
      "id": "uuid",
      "path": "/home/you/Documents",
      "vaultFolderName": "Documents",
      "addedAt": 700000000.0
    }
  ]
}
```

| JSON key | Type | Notes |
|----------|------|-------|
| `sources` | array | list of backup folders |
| `id` | string | stable UUID |
| `path` | string | absolute local cleartext root |
| `vaultFolderName` | string | cleartext folder under `Backups/` in the vault |
| `addedAt` | float64 | seconds since **Apple reference date** 2001-01-01 00:00:00 UTC (Swift `JSONEncoder` / `Date.timeIntervalSinceReferenceDate`) |

`cryptomako sync` **without** `--source` syncs each entry to cleartext `/Backups/{vaultFolderName}/` and keys fingerprints with that `vaultFolderName`. Empty store → helpful error (use `--source`/`--dest` or `sources add`).

Thin CLI (preferred over hand-editing):

```bash
cryptomako sources list
cryptomako sources add /path/to/folder [--vault-folder Name]
cryptomako sources remove ID|PATH
```

Override path: `cryptomako sync --sources /path/to/backup-sources.json` or `cryptomako sources --file …`.

### App preferences (proxy + Sync workers)

Same JSON keys as macOS `Sources/CryptoMakoShared/AppPreferences.swift` (app-group
`app-preferences.json`). Linux XDG path:

`~/.config/cryptomako/app-preferences.json` (or `$XDG_CONFIG_HOME/cryptomako/app-preferences.json`).

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `proxyMode` | string | `system` | `system` \| `direct` \| `custom` |
| `proxyHost` | string | `""` | custom proxy hostname |
| `proxyPort` | int | `8080` | custom proxy port |
| `proxyUsername` | string | `""` | custom proxy user (non-secret) |
| `limitSyncUploadBandwidth` | bool | `false` | pace Backup Sync puts |
| `syncUploadCapMbps` | float | `50` | decimal Mbps when limit on (clamped ≥ 1 on save) |
| `syncSmallPutConcurrency` | int | `96` | clamp 1–256 |
| `syncMediumPutConcurrency` | int | `32` | clamp 1–128 |
| `syncLargePutConcurrency` | int | `4` | clamp 1–16 |

**Proxy password:** env only `CRYPTOMAKO_PROXY_PASSWORD` (macOS uses Keychain). Never put secrets in JSON.

- `proxyMode=system` → honor `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`
- `proxyMode=direct` → bypass proxies
- `proxyMode=custom` → HTTP proxy at `proxyHost:proxyPort` (applied to the S3 HTTPS client)

Backup Sync size tiers (cleartext bytes, same as macOS/Windows): small < 256 KiB, medium < 32 MiB, large ≥ 32 MiB.
Override prefs path: `cryptomako sync --preferences /path/to/app-preferences.json`.

GUI for editing these preferences is **N/A** on Linux CLI (edit JSON or copy from macOS/Windows).

## Packages

| Package | Role |
|---------|------|
| `internal/s3` | SigV4 HTTPS client: GetObject, PutObject, DeleteObject, ListObjectsV2 |
| `internal/vault` | Format-8 **SIV_GCM** unlock / ls / cat (local FS + S3 SigV4) |
| `internal/config` | XDG config, AppPreferences, Backup Sync sources/excludes/state, env secrets |

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
| `accessKey` | Access key id (`accessKeyId` legacy alias) |
| `pathStyle` | Default `true` (virtual-hosted unsupported on Linux) |

Backup sources file (separate): `sources[]` with `id`, `path`, `vaultFolderName`, `addedAt`.

Backup Sync excludes file (separate): `directoryNames`, `fileNames`, `fileExtensions`.

Backup Sync state file (separate): `files` map with `size` + `contentModification` (Apple reference-date seconds); see table above.

App preferences file (separate): `proxyMode`, `proxyHost`, `proxyPort`, `proxyUsername`,
`limitSyncUploadBandwidth`, `syncUploadCapMbps`, sync*PutConcurrency (see table above).

Env secrets: `CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY`, `CRYPTOMAKO_PROXY_PASSWORD` (custom proxy only).

Proposed to Platforms before inventing new keys. Current set matches macOS `ConnectionConfigLoader` / `BackupSources` / `BackupSyncExcludes` / `BackupSyncState` / `AppPreferences` / docs/10-m0-fixture.md.

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


## Install (`.deb`)

No new VaultSettings keys; secrets stay env-only; S3 is path-style (locked with Platforms).

```bash
cd linux
./packaging/build-deb.sh
sudo apt-get install -y ./packaging/dist/cryptomako_*.deb
# Depends: fuse3
```

Or install the binary directly:

```bash
cd linux
go build -o cryptomako .
sudo install -m 0755 cryptomako /usr/local/bin/cryptomako
sudo apt-get install -y fuse3
```

See `packaging/README.md`. CI uploads the `.deb` as artifact `cryptomako-deb`.

## Point `--rw` FUSE + sync at MinIO / R2

Use existing env vars and XDG config — no live cloud credentials in CI.

```bash
# ~/.config/cryptomako/config.json  (no secrets)
# {
#   "endpoint": "https://minio.example:9000",
#   "region": "us-east-1",
#   "bucket": "vaults",
#   "prefix": "cryptomako/",
#   "accessKey": "AK…",
#   "pathStyle": true
# }
# Cloudflare R2: endpoint https://<accountid>.r2.cloudflarestorage.com, region auto, pathStyle true

export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < ../fixtures/PASSWORD)"
export CRYPTOMAKO_SECRET_KEY=…   # never commit

# Writable FUSE (fail-closed PutObject/DeleteObject)
mkdir -p /tmp/cryptomako-mnt
./cryptomako mount --mountpoint /tmp/cryptomako-mnt --rw
# echo hi > /tmp/cryptomako-mnt/new.txt

# Backup Sync (honors backup-sync-excludes.json + optional backup-sources.json)
./cryptomako sync --source ~/Documents/tree --dest /
# or: cryptomako sources add ~/Documents/tree && cryptomako sync
```

Or pass flags instead of the config file:

```bash
./cryptomako mount --rw \
  --endpoint https://minio.example:9000 --bucket vaults --prefix cryptomako/ \
  --access-key AK… --mountpoint /tmp/cryptomako-mnt
```

## License

AGPL-3.0 (same as the parent repo).
