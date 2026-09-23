# CfAPI (Cloud Files) — Windows box required

> Live **Register / Unregister** smoked on Windows 11 (build 26100). **Connect / placeholders /
> Explorer hydrate** still need CsWin32-safe `CF_CALLBACK` marshalling. Do not claim a working
> Explorer mount yet.

CryptoMako’s Explorer surface is **Windows Cloud Files** (CfAPI). Local materialization
is for browse + small transfers; **durable success = remote S3 put/delete 2xx**.
Never treat the CfAPI mount as a backup target (use Backup Sync).

## Project

- `src/CryptoMako.CfApi` — `CloudFilesProvider` + `CldApiNative` (P/Invoke `cldapi.dll`)
- CLI: `cryptomako cfapi platform|status|register|unregister|connect`

## Smoke commands (Windows, no admin required for user folder)

```powershell
cd windows
dotnet publish src\CryptoMako.Cli -c Release -r win-x64 --self-contained false -o artifacts\cli-win-x64
$exe = ".\artifacts\cli-win-x64\cryptomako.exe"
$root = Join-Path $env:LOCALAPPDATA "CryptoMako\SyncRoot"

& $exe cfapi platform
# supported=True  info=build=… revision=… integration=…

New-Item -ItemType Directory -Force -Path $root | Out-Null
& $exe cfapi register --root $root --account default
# registered … (CfRegisterSyncRoot)

& $exe cfapi unregister --root $root
```

Elevation: **not required** if the sync root is under the user profile / LocalAppData and the
process has WRITE_DATA on that folder. System-wide provider registration / SyncRootManager shell
integration may need additional steps later.

## Status (this branch)

| Step | Status |
|------|--------|
| `CfGetPlatformInfo` | ✅ live |
| `CfRegisterSyncRoot` | ✅ live (unit + CLI smoke) |
| `CfUnregisterSyncRoot` | ✅ live |
| `CfConnectSyncRoot` | ❌ E_INVALIDARG (0x80070057) / prior AV with naive callback table — needs CsWin32 `CF_CALLBACK` |
| `FETCH_DATA` hydrate | ❌ blocked on Connect |
| Placeholder create | ❌ blocked on Connect |
| Shell SyncRootManager (Explorer glyph) | ❌ not wired (WinRT `StorageProviderSyncRootManager`) |
| Fail-closed write gate helper | ✅ `AcknowledgeWriteOnlyIfRemoteOk` |

## Fail-closed writes

```
local write → encrypt → S3 PutObject (2xx) → acknowledge CfAPI transfer
                     ↘ any error → surface failure; do not claim durable
```

## Next (Windows)

1. Add CsWin32 / Vanara `CF_CALLBACK` delegates for FETCH_DATA + NOTIFY_FILE_CLOSE.
2. Register with `StorageProviderSyncRootManager` for Explorer UI.
3. Create placeholders from vault `ListAsync`; hydrate via vault `CatAsync`/`GetAsync`.
4. Wire Desktop “Mount” button to register+connect lifecycle.
