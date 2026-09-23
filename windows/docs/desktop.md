# Desktop host

## Avalonia (`CryptoMako.Desktop`)

Cross-platform host sharing `CryptoMako.App` ViewModels (Vault / Backup / Settings).

```bash
cd windows
dotnet build src/CryptoMako.Desktop
dotnet run --project src/CryptoMako.Desktop
```

Works on **macOS** (UI smoke) and **Windows** (intended daily driver until WinUI lands).

## Windows-native notes

- Tray / CfAPI registration: Windows box required (`docs/cfapi.md`).
- Secrets: `cryptomako cred` → Credential Manager on Windows, process env on Mac.
- Settings paths: `%AppData%/CryptoMako/settings.json` + `app-preferences.json`.
