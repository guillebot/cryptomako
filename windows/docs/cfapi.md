# CfAPI (Cloud Files) — Windows

Live on Windows 11 (smoked on build 26100): **Register / Connect / placeholders / FETCH_DATA hydrate**.
Explorer can open a placeholder file and receive cleartext from a vault session.
Shell glyph via full `StorageProviderSyncRootManager` is still best-effort (HKCU SyncRootManager stub).

Durable success remains **remote S3 put/delete 2xx** — never the local placeholder.

## Project

- `src/CryptoMako.CfApi` — Vanara.PInvoke.CldApi-backed `CloudFilesProvider`
- CLI: `cryptomako cfapi platform|status|register|unregister|connect|populate`

## Smoke (no admin for user LocalAppData root)

```powershell
cd windows
dotnet publish src\CryptoMako.Cli -c Release -r win-x64 --self-contained false -o artifacts\cli-win-x64
$exe = ".\artifacts\cli-win-x64\cryptomako.exe"
$root = Join-Path $env:LOCALAPPDATA "CryptoMako\SyncRoot"
$env:CRYPTOMAKO_PASSWORD = (Get-Content ..\fixtures\PASSWORD -Raw).Trim()

& $exe cfapi platform
& $exe cfapi populate --root $root --account default --local ..\fixtures\vault
# placeholders=N — process holds ~90s so Explorer/ReadFile can FETCH_DATA
# Observed: reading hello.txt returns "hello cryptomako\n"

& $exe cfapi unregister --root $root
```

Elevation: **not required** for `%LOCALAPPDATA%\CryptoMako\…`.

## Status

| Step | Status |
|------|--------|
| `CfGetPlatformInfo` | ✅ |
| `CfRegisterSyncRoot` / `Unregister` | ✅ |
| `CfConnectSyncRoot` + Vanara `CF_CALLBACK` | ✅ FETCH_DATA / CANCEL / CLOSE |
| `CfCreatePlaceholders` | ✅ root populate from vault list |
| `FETCH_DATA` → vault `CatAsync` → `CfExecute(TRANSFER_DATA)` | ✅ smoke: hello.txt |
| Fail-closed write gate | ✅ `AcknowledgeWriteOnlyIfRemoteOk` (writes not auto-acked on CLOSE) |
| WinRT `StorageProviderSyncRootManager` | 🟡 HKCU SyncRootManager stub only — full WinRT glyph TBD |
| Recursive dir placeholders / rename / delete callbacks | ❌ deferred |
| S3-backed hydrate (non-local vault) | 🟡 same path once session attached |

## Fail-closed writes

```
local write → encrypt → S3 PutObject (2xx) → AcknowledgeWriteOnlyIfRemoteOk(true)
                     ↘ any error → do not claim durable
```

NOTIFY_FILE_CLOSE does **not** acknowledge vault mutations.
