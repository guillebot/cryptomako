# CryptoMako Windows

Windows port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over HTTPS, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `windows/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault.

## Surfaces (locked)

| Surface | Role |
|---------|------|
| **Explorer (CfAPI / Cloud Files)** | Browse + small transfers. Local materialization is **never** “backed up.” |
| **Backup Sync** | Large trees: walk → encrypt → remote put. Fail-closed. |

## Requirements

- .NET 8 SDK
- Vault password in `CRYPTOMAKO_PASSWORD` (never argv; never JSON)
- S3 secret in `CRYPTOMAKO_SECRET_KEY` (Credential Manager later)
- S3 endpoints **https only** (http rejected)

## Build

```bash
cd windows
export PATH="$HOME/.dotnet:$PATH"   # macOS/Linux host
dotnet build
dotnet test
```

## Local golden vault

```bash
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < ../fixtures/PASSWORD)"
dotnet run --project src/CryptoMako.Cli -- unlock --local ../fixtures/vault
dotnet run --project src/CryptoMako.Cli -- ls --local ../fixtures/vault --path / -R
dotnet run --project src/CryptoMako.Cli -- cat --local ../fixtures/vault /hello.txt
dotnet run --project src/CryptoMako.Cli -- get --local ../fixtures/vault /hello.txt -o /tmp/hello.txt
dotnet run --project src/CryptoMako.Cli -- stat --local ../fixtures/vault /hello.txt
```

## S3 / MinIO (no live bucket required for unit tests)

```bash
export CRYPTOMAKO_PASSWORD='…'
export CRYPTOMAKO_SECRET_KEY='…'
dotnet run --project src/CryptoMako.Cli -- unlock \
  --endpoint https://minio.example:9000 \
  --region us-east-1 \
  --bucket vaults \
  --prefix team/demo/ \
  --access-key minio \
  # path-style by default; add --virtual-hosted for AWS-style URLs

dotnet run --project src/CryptoMako.Cli -- ls \
  --endpoint https://minio.example:9000 --bucket vaults --prefix team/demo/ \
  --access-key minio --path / -R
```

Or put non-secret fields in `%AppData%/CryptoMako/settings.json` / `~/.config/cryptomako/poc.json`:

```json
{
  "storageMode": "s3",
  "endpoint": "https://minio.example:9000",
  "region": "us-east-1",
  "bucket": "vaults",
  "prefix": "team/demo/",
  "accessKey": "minio",
  "localVaultPath": "",
  "autoReconnect": false,
  "pathStyle": true
}
```

Then: `cryptomako unlock --config /path/to/settings.json`

## Settings keys (Platforms-locked — do not invent)

**VaultSettings:** `storageMode`, `endpoint`, `region`, `bucket`, `prefix`, `accessKey`, `localVaultPath`, `autoReconnect`, `pathStyle`

**AppPreferences:** `proxyMode`, `proxyHost`, `proxyPort`, `proxyUsername`, `limitSyncUploadBandwidth`, `syncUploadCapMbps`, `syncSmallPutConcurrency`, `syncMediumPutConcurrency`, `syncLargePutConcurrency`

**Excludes:** `directoryNames`, `fileNames`, `fileExtensions`

Secrets: env / Credential Manager only.

## Desktop + CfAPI

- **Desktop (Avalonia) + tray:** `dotnet run --project src/CryptoMako.Desktop` — Vault / Backup / Settings; tray unlock/lock/probe/open/quit (close hides to tray). See `docs/desktop.md`.
- **CfAPI:** `cryptomako cfapi register|unregister` live on Windows 11; Connect/hydrate still blocked (`docs/cfapi.md`).
- **Parity checklist:** `docs/parity.md` · packaging: `docs/packaging.md`.
- **Credentials CLI:** `cryptomako cred list|get|set|delete` (stdin for set; Credential Manager on Windows).

## Backup Sync

```bash
dotnet run --project src/CryptoMako.Cli -- sync --local ../fixtures/vault \
  --source /path/to/cleartext --vault-folder MyHost
# uploads under /Backups/MyHost/… with excludes + size-tiered put workers
```

Workers / bandwidth / proxy: `%AppData%/CryptoMako/app-preferences.json` (Platforms-locked keys).
Secrets: env or Windows Credential Manager (`CryptoMako/CRYPTOMAKO_*`).

## Acceptance

- `dotnet test` green (golden + SigV4 + settings + Backup Sync + proxy mapping)
- Local CLI matches `fixtures/expected-ls.txt` and hello.txt
- S3 client: get/list/put/delete over HTTPS with SigV4; unlock/ls/cat/get/stat/sync/delete/rename/mkdir/put wired
- autoReconnect connectivity monitor (Desktop); parity checklist: `docs/parity.md`
- Proxy modes system|direct|custom applied to S3 HttpClient

## Remaining for Windows box

See **`docs/parity.md`** for the full macOS ↔ Windows checklist.

Still needs a real Windows machine:

1. Live **CfAPI / Explorer** mount (stubs only on Mac — never claim mount works from Mac CI)
2. Smoke **Avalonia tray** + Credential Manager on Windows
3. **`dotnet publish -r win-x64`** packaging smoke (`docs/packaging.md`); MSIX/WinUI later

Non-CfAPI library/CLI/Desktop paths (unlock, browse, mutations, Backup Sync, proxy, auto-reconnect) are intended to work on Mac host builds.

## License

AGPL-3.0 (same as the parent repo).
