# CfAPI (Cloud Files) — Windows box required

> **Not live on macOS.** Stubs compile for solution green builds. Explorer mount / placeholder sync
> must be validated on a real Windows machine. Do not treat Mac `dotnet build` of `CryptoMako.CfApi`
> as evidence of a working mount.

CryptoMako’s Explorer surface is **Windows Cloud Files** (CfAPI). Local materialization
is for browse + small transfers; **durable success = remote S3 put/delete 2xx**.
Never treat the CfAPI mount as a backup target (use Backup Sync).

## Project

- `src/CryptoMako.CfApi` — managed stubs (`CloudFilesProvider`) that compile on macOS/Linux.
- Real `CfRegisterSyncRoot` / callbacks need **Windows 10 1803+** and a Windows build box.

## Registration checklist (on Windows)

1. Build: `dotnet build src/CryptoMako.CfApi -c Release` (and the desktop host).
2. Pick a sync root directory, e.g. `%USERPROFILE%\CryptoMako`.
3. Register the sync root with:
   - Provider name: `CryptoMako`
   - Sync root id: `CryptoMako!<account>` (unique per vault connection)
   - Display name / icon resource
4. Connect callbacks:
   - `FETCH_DATA` / `FETCH_PLACEHOLDERS` → vault `get` / `list` over S3 or local store
   - `NOTIFY_FILE_CLOSE_COMPLETION` / write path → encrypt + **remote put**; only then report success
5. Hydrate on demand; pin policy = optional. Fail closed on transport errors.
6. Unregister on logout / vault lock.

## Fail-closed writes

```
local write → encrypt → S3 PutObject (2xx) → acknowledge CfAPI transfer
                     ↘ any error → surface failure; do not claim durable
```

## Build notes

| Host | What works |
|------|------------|
| macOS (this repo’s current host) | Stub compile + unit tests for libraries; **no** live CfAPI |
| Windows 10/11 + VS 2022 | Full register/smoke; add CsWin32/`cfsapi` P/Invoke |

Ship UI: `CryptoMako.Desktop` (Avalonia) builds on Mac for smoke and on Windows for daily use.
A future WinUI shell can reuse `CryptoMako.App` ViewModels.
