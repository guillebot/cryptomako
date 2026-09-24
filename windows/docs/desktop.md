# Desktop host

## WinUI 3 (`CryptoMako.Desktop`)

Windows-native Fluent host sharing `CryptoMako.App` ViewModels (Vault / Backup / Settings).
Unpackaged (`WindowsPackageType=None`) with self-contained Windows App SDK.

### Requirements

- .NET 8 SDK
- Windows 10 1809+ (Cloud Files / CfAPI soft viewer needs 1803+)
- NuGet restore pulls `Microsoft.WindowsAppSDK` + BuildTools (no Visual Studio required for `dotnet build`)

### Run

```powershell
cd windows
dotnet build src/CryptoMako.Desktop -c Release -p:Platform=x64
dotnet run --project src/CryptoMako.Desktop -c Release -p:Platform=x64
```

Publish:

```powershell
pwsh ./scripts/publish-win-x64.ps1
```

### Status strip

Top of the main window (left → right):

| Element | Source | Prominence |
|---------|--------|------------|
| Probe lamps | dns → tcp → https → list (`LastProbe`) | Secondary |
| Explorer badge | `IsExplorerViewerConnected` (soft CfAPI) | Secondary |
| **Vault badge** (top-right) | `IsUnlocked` / Busy → Locked / Unlocked / Busy… | **Primary** (larger/bolder) |

Backup **Sync now** is `IsEnabled` only while `IsUnlocked` (greyed when locked/disconnected). Soft CfAPI connect failure after Unlock does **not** clear vault-unlocked (macOS soft Finder semantics).

### System tray

`H.NotifyIcon.WinUI` notification-area icon (brand `docs/assets/brand/tray-windows.png` → `Assets/tray.ico`):

| Action | Behavior |
|--------|----------|
| Click tray / **Open CryptoMako** | Show + activate main window |
| **Unlock** / **Lock** | Same as Vault tab |
| **Probe S3** | dns / tcp / https / list lamps |
| Status + Probe lines | Read-only labels |
| **Quit** | Explicit shutdown (only quit path) |
| Close window (✕) | **Hides** to tray (does not quit) |
| Minimize | **Hides** to tray |

### Native folder picker

Backup tab **Browse…** uses WinRT `FolderPicker` + `InitializeWithWindow` (StorageFolder path).

### Soft CfAPI Explorer viewer

After successful **Unlock**, Desktop binds live `CloudFilesProvider` to `MainViewModel.ExplorerViewer` (auto + **Connect Explorer**). **Lock** cancels Backup Sync, then `DisconnectExplorerViewer()` (disconnect + clear binding). **CredMan is not wiped.** Sync-root unregister happens on process exit / explicit tear-down, not Lock.

**Connect Explorer** keeps `CfConnectSyncRoot` alive even if placeholder seed fails (soft populate) — a registered-but-disconnected sync root makes Explorer show *cloud operation is invalid*. On hard connect failure the controller unregisters to avoid orphans. Success opens File Explorer at `%LOCALAPPDATA%\CryptoMako\SyncRoot`. The status-strip Explorer badge and **Open sync root** link open that folder when connected.

### Auto Probe S3

Background connectivity monitor (≈20s, same cadence as macOS) updates dns/tcp/https/list lamps via `LastProbe` (manual **Probe S3** unchanged). Overlapping probes are debounced; UI is not blocked.

### Backup Sync progress

Backup tab shows a ProgressBar plus percent / files / bytes / speed / ETA / current path while Sync runs (macOS BackupSyncEngine parity). Metrics settle on complete / cancel / error.


### Brand icons

- Explorer SyncRoot: %LOCALAPPDATA%\CryptoMako\Assets\AppIcon.ico,0 (copied from Desktop Assets/AppIcon.ico on Register; replaces shell32.dll,50 dark tile)

- Window / app: `Assets/AppIcon.ico` from `docs/assets/brand/icon-{16,32,48,256}.png`
- Tray: `Assets/tray.ico` from `docs/assets/brand/tray-windows.png`

### Secret lifetime (in-process)

While unlocked, masterkey bytes live in `Masterkey`/`Cryptor` and the S3 secret access key string lives in `S3Settings` for SigV4. **Lock / Dispose** zeros masterkey buffers, clears the UI passphrase field, and drops the S3 `SecretKey` reference (`ClearSecretKey`). SigV4 signing keys and ephemeral HMAC intermediates are `ZeroMemory`'d after each request.

**Lock High (Platforms):** cancel in-flight Backup Sync, then disconnect the soft CfAPI viewer (`IExplorerViewer.Disconnect`). Keep existing in-process secret clearing (masterkey zero / UI passphrase clear / S3 `SecretKey` drop). **CredMan wipe is deferred** — Lock must not call `DeleteSecret`. **Not scrubbed (Medium residual):** .NET immutable strings (passphrase, S3 secret, proxy password in `NetworkCredential`) until GC.

### autoReconnect

When **auto-reconnect** is checked (VaultSettings `autoReconnect`, no new keys):

- On launch / toggle: attempt unlock if password + (local path | S3 secrets) are available.
- Background probe ~every 20s; after an outage→reachable transition, unlock again if the user still wants an unlocked session (Unlock sets that; Lock clears it).

## Needs a Windows box (CfAPI / Explorer)

Live **Cloud Files API** registration and Explorer placeholder mount are **Windows-only**. See `docs/cfapi.md`.

## Windows-native notes

- Secrets: `cryptomako cred` → Credential Manager on Windows (`get` requires `--reveal`); env / `~/.config/cryptomako/secrets.json` on Mac hosts for CLI-only work.
- Settings paths: `%AppData%/CryptoMako/settings.json` + `app-preferences.json` (Windows).
