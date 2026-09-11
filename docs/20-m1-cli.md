# M1 — CLI

Executable: `cryptomako`.

Secrets: `CRYPTOMAKO_PASSWORD` and `CRYPTOMAKO_SECRET_KEY` (override env names with `--password-env` / `--secret-key-env`). Never pass passphrase or secret key on argv.

## Commands

```text
cryptomako unlock --endpoint URL --region REGION --bucket BUCKET --prefix PREFIX --access-key KEY
cryptomako ls [--path /] [-R]
cryptomako cat <cleartext-path>
```

`unlock` prints `format`, `cipherCombo`, and the root ciphertext prefix (`d/XX/YYY…`) and exits 0.

`ls` prints cleartext names; directories end with `/`. `-R` walks `dir.c9r` links.

`cat` downloads ciphertext, decrypts with `Cryptor.decryptContent`, writes plaintext to stdout.

## Connection flags

| Flag | Meaning |
|------|---------|
| `--endpoint` | S3 API URL (no bucket in path) |
| `--region` | Region string (MinIO: `us-east-1`) |
| `--bucket` | Bucket name |
| `--prefix` | Vault prefix, trailing slash normalized |
| `--access-key` | Access key id |
| `--config` | Optional JSON path (default `~/.config/cryptomako/poc.json`) |

`poc.json` must not contain the secret key or vault password.

## Acceptance

- `cryptomako ls -R /` matches `fixtures/expected-ls.txt` for the operator fixture.
- `cryptomako cat /hello.txt` is exactly the fixture bytes.
- Wrong password or missing JWT → exit 1, no key material in the message.
