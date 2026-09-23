# Windows product notes

## Goal

Any S3-compatible bucket → Cryptomator format 8 over HTTPS → cleartext UX on Windows. Bucket sees only unrecognizable names and contents. Durable success = remote put/delete only.

## Layout

Code lives in `windows/` of guillebot/cryptomako. Golden vault: repo `fixtures/`.

## Stack

- .NET 8 CLI first (`cryptomako` unlock / ls / cat)
- Explorer: Windows Cloud Files (CfAPI) for browse + small transfers
- Backup Sync: separate path for large trees (do not point bulk tools at the CfAPI mount)
- Crypto: Cryptomator-compatible format 8 (prefer cryptolib-java interop or verified equivalent)

## Secrets

Never in JSON. `CRYPTOMAKO_PASSWORD`, `CRYPTOMAKO_SECRET_KEY`, or Windows Credential Manager.
