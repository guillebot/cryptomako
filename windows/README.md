# CryptoMako Windows

Windows port of [CryptoMako](https://github.com/guillebot/cryptomako): S3-compatible bucket → Cryptomator **format 8** vault over HTTPS, cleartext UX locally, unrecognizable names+contents in the bucket.

Lives under `windows/` in the main repo (not a sibling). Shares `fixtures/` with macOS as the golden vault.

## Surfaces (locked)

| Surface | Role |
|---------|------|
| **Explorer (CfAPI / Cloud Files)** | Browse + small transfers. Local materialization is **never** “backed up.” |
| **Backup Sync** | Large trees: walk → encrypt → remote put. Fail-closed. |

This folder’s first milestone is the **CLI** (`unlock` / `ls` / `cat`) against `../fixtures/vault`.

## Requirements

- .NET 8 SDK
- Vault password in `CRYPTOMAKO_PASSWORD` (never argv; never JSON)
- S3 secret (later) in `CRYPTOMAKO_SECRET_KEY` or Windows Credential Manager

## Build

```powershell
cd windows
dotnet build
dotnet run --project src/CryptoMako.Cli -- unlock --local ..\fixtures\vault
```

On macOS (dev host):

```bash
cd windows
dotnet build
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < ../fixtures/PASSWORD)"
dotnet run --project src/CryptoMako.Cli -- unlock --local ../fixtures/vault
dotnet run --project src/CryptoMako.Cli -- ls --local ../fixtures/vault --path / -R
```

## Acceptance (W0 / W1)

- `dotnet test` green (golden unlock + recursive ls + cat)
- `ls --local ../fixtures/vault --path / -R` matches `../fixtures/expected-ls.txt`
- `cat --local ../fixtures/vault /hello.txt` matches fixture bytes (`hello cryptomako\n`)
- Wrong password → exit 1, no key material in the message
- Crypto: Cryptomator format 8 SIV_GCM (scrypt + AES-KW + AES-SIV names + SIV_GCM content), mirrored from cryptolib-swift

## Config shape (draft — post to Platforms before inventing keys)

Non-secret JSON (e.g. `%AppData%/CryptoMako/settings.json`):

- `endpoint`, `region`, `bucket`, `prefix` (vault folder containing `vault.cryptomator`)
- `accessKey`

Secrets: OS store / env only.

## License

AGPL-3.0 (same as the parent repo).
