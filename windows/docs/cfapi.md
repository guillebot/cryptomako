# CfAPI (Cloud Files) — Windows

Live on Windows 11 (smoked on build 26100): **Register / Connect / recursive placeholders / FETCH_DATA hydrate**.
Explorer can open a placeholder file and receive cleartext from a vault session.
Shell cloud UI uses real **WinRT `StorageProviderSyncRootManager`** on `net8.0-windows10.0.19041.0` builds
(Id format `CryptoMako!{SID}!{account}`; WinRT Register also registers with CfAPI — do not call `CfRegisterSyncRoot` after it).
`net8.0` / non-Windows falls back to `CfRegisterSyncRoot` + HKCU SyncRootManager stub.

Durable success remains **remote S3 put/delete 2xx** — never the local placeholder.

## Project

- `src/CryptoMako.CfApi` — multi-targets `net8.0` + `net8.0-windows10.0.19041.0` (Vanara + WinRT)
- CLI: `cryptomako cfapi platform|status|register|unregister|connect|populate`
- Publish Windows CLI with `-f net8.0-windows10.0.19041.0` (Cli forces matching CfApi TFM)

## Smoke (no admin for user LocalAppData root)

```powershell
cd windows
dotnet publish src\CryptoMako.Cli -c Release -f net8.0-windows10.0.19041.0 -r win-x64 --self-contained false -o artifacts\cli-win-x64
$exe = ".\artifacts\cli-win-x64\cryptomako.exe"
$root = Join-Path $env:LOCALAPPDATA "CryptoMako\SyncRoot"
$env:CRYPTOMAKO_PASSWORD = (Get-Content ..\fixtures\PASSWORD -Raw).Trim()

& $exe cfapi platform
& $exe cfapi populate --root $root --account default --local ..\fixtures\vault
# placeholders=N (recursive: bin/, notes/, hello.txt, …); shell=WinRT StorageProviderSyncRootManager
# Explorer: sync root under LocalAppData; cloud glyph via SyncRootManager; open hello.txt to hydrate

& $exe cfapi unregister --root $root --account default
```

Elevation: **not required** for `%LOCALAPPDATA%\CryptoMako\…`.
Prefer **`cfapi unregister`** over killing the process so WinRT + CfAPI metadata are cleared.

## Status

| Step | Status |
|------|--------|
| `CfGetPlatformInfo` | OK |
| `CfRegisterSyncRoot` / `Unregister` | OK (fallback path); WinRT path uses SyncRootManager.Register instead |
| `CfConnectSyncRoot` + Vanara `CF_CALLBACK` | OK FETCH_DATA / CANCEL / CLOSE / DELETE / RENAME |
| `CfCreatePlaceholders` | OK recursive populate (dirs then nested files) |
| `FETCH_DATA` → vault `CatAsync` → `CfExecute(TRANSFER_DATA)` | OK smoke: hello.txt |
| Fail-closed write gate | OK `AcknowledgeWriteOnlyIfRemoteOk` |
| WinRT `StorageProviderSyncRootManager` | OK on windows TFM (`CryptoMako!SID!account`) |
| NOTIFY_DELETE / NOTIFY_RENAME | Fail-closed ACK (ACCESS_DENIED) until vault mutation + remote 2xx |
| S3-backed hydrate (non-local vault) | Same path once session attached |

## Fail-closed writes / delete / rename

```
local write → encrypt → S3 PutObject (2xx) → AcknowledgeWriteOnlyIfRemoteOk(true)
                     ↘ any error → do not claim durable
```

NOTIFY_FILE_CLOSE does **not** acknowledge vault mutations.
NOTIFY_DELETE / NOTIFY_RENAME currently ACK with `STATUS_CLOUD_FILE_ACCESS_DENIED`
(TODO: allow after remote delete/rename 2xx).
