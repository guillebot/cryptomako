# Packaging (Windows)

## Framework-dependent (dev)

```bash
cd windows
dotnet publish src/CryptoMako.Cli -c Release -r win-x64 --self-contained false -o artifacts/cli-win-x64
dotnet publish src/CryptoMako.Desktop -c Release -r win-x64 --self-contained false -o artifacts/desktop-win-x64
```

Requires .NET 8 Desktop Runtime on the target machine.

## Self-contained single-folder

```bash
dotnet publish src/CryptoMako.Desktop -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=false -o artifacts/desktop-win-x64-sc
```

## Notes

- Build/publish for `win-x64` can run on a Mac host (cross-compile); **run** Desktop/CfAPI on Windows.
- No MSIX/installer in-tree yet — ship the publish folder or wrap later on a Windows box.
- Never bake `CRYPTOMAKO_*` secrets into publish output or settings JSON.
- CfAPI registration is **not** part of publish; see `docs/cfapi.md`.
