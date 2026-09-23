# Desktop host

## Avalonia (`CryptoMako.Desktop`)

Cross-platform host sharing `CryptoMako.App` ViewModels (Vault / Backup / Settings).

```bash
cd windows
dotnet build src/CryptoMako.Desktop
dotnet run --project src/CryptoMako.Desktop
```

Works on **macOS** (UI + tray smoke) and **Windows** (intended daily driver until WinUI lands).

### System tray / status item

Avalonia `TrayIcon` (Mac menu bar / Windows notification area):

| Action | Behavior |
|--------|----------|
| Click tray / **Open CryptoMako** | Show + activate main window |
| **Unlock** / **Lock** | Same as Vault tab |
| **Probe S3** | dns / tcp / https / list lamps |
| Status + Probe lines | Read-only labels (● ok / ✖ fail / – skip) |
| **Quit** | Explicit shutdown |
| Close window (✕) | **Hides** to tray (does not quit) |

`ShutdownMode=OnExplicitShutdown` so the process stays alive while hidden.

## Needs a Windows box (CfAPI / Explorer)

Live **Cloud Files API** registration and Explorer placeholder mount are **Windows-only**. The `CryptoMako.CfApi` project on Mac is **stubs + docs only** — it does not claim a working Explorer mount. See `docs/cfapi.md`.

## Windows-native notes

- Secrets: `cryptomako cred` → Credential Manager on Windows (`get` requires `--reveal`); env / `~/.config/cryptomako/secrets.json` on Mac.
- Settings paths: `%AppData%/CryptoMako/settings.json` + `app-preferences.json` (Windows); `~/.config/cryptomako/` on Mac.

### Secret lifetime (in-process)

While unlocked, masterkey bytes live in `Masterkey`/`Cryptor` and the S3 secret access key string lives in `S3Settings` for SigV4. **Lock / Dispose** zeros masterkey buffers, clears the UI passphrase field, and drops the S3 `SecretKey` reference (`ClearSecretKey`). SigV4 signing keys and ephemeral HMAC intermediates are `ZeroMemory`'d after each request.

**Lock High (Platforms):** cancel in-flight Backup Sync, then disconnect the soft CfAPI viewer (`IExplorerViewer.Disconnect`). Keep existing in-process secret clearing (masterkey zero / UI passphrase clear / S3 `SecretKey` drop). **CredMan wipe is deferred** — Lock must not call `DeleteSecret`. **Not scrubbed (Medium residual):** .NET immutable strings (passphrase, S3 secret, proxy password in `NetworkCredential`) until GC.

### autoReconnect

When **auto-reconnect** is checked (VaultSettings `autoReconnect`, no new keys):

- On launch / toggle: attempt unlock if password + (local path | S3 secrets) are available.
- Background probe ~every 20s; after an outage→reachable transition, unlock again if the user still wants an unlocked session (Unlock sets that; Lock clears it).

## Soft CfAPI Explorer viewer wiring

On Windows, after a successful **Unlock**, Desktop binds the live `CloudFilesProvider` to `MainViewModel.ExplorerViewer` (auto + **Connect Explorer** button). **Lock** cancels Backup Sync, then `DisconnectExplorerViewer()` (disconnect + clear binding). CredMan is not wiped. Sync-root unregister happens on process exit / explicit tear-down, not Lock.

