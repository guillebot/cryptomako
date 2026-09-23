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

### autoReconnect

When **auto-reconnect** is checked (VaultSettings `autoReconnect`, no new keys):

- On launch / toggle: attempt unlock if password + (local path | S3 secrets) are available.
- Background probe ~every 20s; after an outage→reachable transition, unlock again if the user still wants an unlocked session (Unlock sets that; Lock clears it).

