# CfAPI (Cloud Files) — Windows

Live on Windows 11 (smoked on build 26100): **Register / Connect / placeholders / FETCH_DATA hydrate / FETCH_PLACEHOLDERS**.
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

## Sync-root policies (dehydrate / pin / populate)

Chosen to avoid surprising full-hydrate of huge vault trees:

| Policy | WinRT (`StorageProviderSyncRootInfo`) | CfRegister (`CF_SYNC_POLICIES`) |
|--------|----------------------------------------|----------------------------------|
| Hydration | **Partial** | **PARTIAL** |
| Hydration modifier | **AutoDehydrationAllowed** | **AUTO_DEHYDRATION_ALLOWED** |
| Population | **Full** (WinRT has no Partial; not AlwaysFull) | **PARTIAL** |
| Pinning | **AllowPinning = true** (user "Always keep on device") | n/a (Explorer pin via shell) |
| Hard links | None | None |

Rationale: Partial hydration streams on demand (FETCH_DATA); AutoDehydrationAllowed lets the OS free space; population is on-demand (Cf PARTIAL / WinRT Full) — never AlwaysFull, which would force dense placeholder trees. Pinning is opt-in per item, not global.

`CloudFilesProvider.SyncPolicySummary` / `GetStatus().PolicySummary` expose the same summary for tests and CLI status.

## Status

| Step | Status |
|------|--------|
| `CfGetPlatformInfo` | OK |
| `CfRegisterSyncRoot` / `Unregister` | OK (fallback path); WinRT path uses SyncRootManager.Register instead |
| `CfConnectSyncRoot` + Vanara `CF_CALLBACK` | OK FETCH_DATA / CANCEL / CLOSE / DELETE / RENAME |
| `CfCreatePlaceholders` | OK populate (default: root level only; `--recursive` for full tree) |
| `FETCH_PLACEHOLDERS` | OK one vault directory level ? `TRANSFER_PLACEHOLDERS` + disable on-demand for that folder |
| `FETCH_DATA` → vault `CatAsync` → `CfExecute(TRANSFER_DATA)` | OK smoke: hello.txt |
| Fail-closed write gate | OK `AcknowledgeWriteOnlyIfRemoteOk` |
| WinRT `StorageProviderSyncRootManager` | OK on windows TFM (`CryptoMako!SID!account`) |
| NOTIFY_DELETE / NOTIFY_RENAME | OK vault mutation then ACK SUCCESS; ACCESS_DENIED on failure |
| NOTIFY_RENAME FileIdentity | OK `CfUpdatePlaceholder` to new cleartext path after vault rename |
| NOTIFY_FILE_CLOSE_COMPLETION | OK write-back via `PutAtCleartextPathAsync`; mark in-sync only on success |
| Dehydrate / pin / populate policies | OK Partial + AutoDehydrationAllowed; AllowPinning; no AlwaysFull |
| S3-backed hydrate (non-local vault) | Same path once session attached |

## Fail-closed writes / delete / rename

```
local write → CLOSE_COMPLETION → encrypt → S3 PutObject (2xx) → CfSetInSyncState(IN_SYNC)
                     ↘ any error → leave dirty (do not claim durable)
```

NOTIFY_FILE_CLOSE_COMPLETION is **completion-only** (no deny ACK). Fail-closed means:
do not mark in-sync / do not treat as durable when remote put fails.

NOTIFY_DELETE / NOTIFY_RENAME call vault `DeleteAsync` / `RenameAsync` (fail-closed on store errors),
then ACK `STATUS_SUCCESS` only on success; otherwise `STATUS_CLOUD_FILE_ACCESS_DENIED`.
After a successful rename, FileIdentity is updated to the new vault path before ACK.

## Conflicts / merge (residual — not implemented)

CryptoMako does **not** ship a merge engine. Concurrent remote vs local edits are fail-closed / last-writer-wins at the object-store layer only:

- Local CLOSE write-back overwrites the ciphertext object on successful put (no 3-way merge, no conflict copies).
- Remote changes are not watched; there is no background reconcile, etag precondition, or "conflicted copy" like Finder File Provider.
- Toward Finder-FP parity this remains an explicit gap: needs remote change detection + user-visible conflict policy before claiming multi-device sync safety.

## Explorer cloud glyph smoke (monster / Win11 build 26100)

Evidence collected while `cfapi populate` / `connect` registered a LocalAppData sync root:

1. **HKCU SyncRootManager** entry present: `CryptoMako!{SID}!{account}` with
   `DisplayNameResource=CryptoMako`, `IconResource=%SystemRoot%\system32\shell32.dll,50`,
   `UserSyncRootPath` under `%LOCALAPPDATA%\CryptoMako\…`.
2. Opening the sync root in Explorer **after** the provider process exits shows
   **"The cloud file provider is not running"** — Explorer treats the folder as a
   Cloud Files sync root (provider-aware / glyph path). While the provider is
   connected, placeholders are accessible; nested dirs + `hello.txt` hydrate via FETCH_DATA.
3. On this host `StorageProviderSyncRootManager.GetCurrentSyncRoots()` may still
   report count=0 while the HKCU stub + CfRegister path is active — shell visibility
   then relies on the SyncRootManager registry key (belt-and-suspenders). WinRT
   Register remains preferred when it succeeds (`ShellRegistration=WinRT …`).

Search indexer: not tuned this pass (AllowPinning + Partial hydrate is enough for now).

## Remaining blockers toward Finder-FP parity

1. No conflict/merge / remote-change watcher (see Conflicts section).
2. CLOSE cannot deny the close; remote put failure leaves local bytes dirty (no revert).
3. No FETCH_PLACEHOLDERS on-demand listing beyond pre-populated placeholders.
4. Search indexer / offline availability UX not tuned beyond AllowPinning + AutoDehydrationAllowed.
5. WinRT `GetCurrentSyncRoots` empty on some hosts while Cf+registry path still provides Explorer awareness — investigate WinRT Register reliability.
