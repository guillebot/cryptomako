# M0 — Fixture

Goal: a MinIO bucket whose plaintext you know, created by **stock Cryptomator**, not by CryptoMako.

## MinIO

```bash
./scripts/minio-up.sh
```

Defaults:

| Setting | Value |
|---------|--------|
| API | `http://127.0.0.1:9000` |
| Console | `http://127.0.0.1:9001` |
| User | `cryptomako` |
| Password | `cryptomako-minio-dev` |
| Bucket | `cryptomako-poc` |

## Create the vault

1. In Cryptomator desktop, create a vault in a local folder (format 8, password stored only in gitignored `fixtures/PASSWORD`).
2. Unlock and add a known tree, for example:
   - `hello.txt` = `hello cryptomako\n`
   - `notes/todo.md` = two lines
   - a small PDF or PNG under `bin/`
   - a Unicode name (`café résumé.txt`)
   - optional: a very long name to force `.c9s`
3. Lock the vault.
4. Copy the vault directory (ciphertext) into MinIO at prefix `family/` of bucket `cryptomako-poc`.
5. Record `cryptomako ls -R /` output in `fixtures/expected-ls.txt`.

Acceptance:

- The prefix contains `family/vault.cryptomator`, `family/masterkey.cryptomator`, and `family/d/…`.
- Stock Cryptomator can still unlock a re-download of that prefix.

The operator creates this fixture. The CLI cannot click Cryptomator’s UI.
