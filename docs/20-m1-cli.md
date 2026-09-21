# M1 — CLI

Executable: `cryptomako`.

Product binary: `swift run cryptomako` (lowercase). The `CryptoMako` product is the GUI app.

Secrets: `CRYPTOMAKO_PASSWORD` and `CRYPTOMAKO_SECRET_KEY` (override env names with `--password-env` / `--secret-key-env`). Never pass passphrase or secret key on argv.

## Commands

```text
cryptomako unlock [--local DIR | --endpoint URL --bucket BUCKET …]
cryptomako ls [--path /] [-R | --recursive]
cryptomako cat <cleartext-path>
cryptomako get <cleartext-path> --output FILE
cryptomako stat <cleartext-path>
cryptomako fixture [--output DIR] [--password-file PATH]
```

`--local DIR` unlocks a vault directory on disk. No S3 credentials. Password still comes from `CRYPTOMAKO_PASSWORD`. This is the unsigned-development path: same `VaultSession` the File Provider will use.

`get` decrypts file-to-file (what `fetchContents` does). `stat` prints kind, item id, ciphertext size, and key.

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
| `--local` | Vault directory on disk; skips S3 |

`poc.json` must not contain the secret key or vault password.

## Transport

S3 requests are signed in-process (`CryptoMakoS3/SigV4.swift`) and sent with
`URLSession`. Two details are load-bearing and covered by tests:

- The canonical path is read from `percentEncodedPath`, not `URL.path`, which
  strips a trailing slash and breaks `ListObjectsV2` on `/bucket/` while leaving
  object GETs working.
- The wire query is assigned from `SigV4.canonicalQueryString`, because
  `URLComponents` leaves `/` raw in query values where SigV4 requires `%2F`.

A bare CLI binary is not subject to App Transport Security, so a plain-HTTP
endpoint works here. The sandboxed app and extension are (see
`docs/30-m2-file-provider.md`).

## Acceptance

- `cryptomako ls --local fixtures/vault --path / --recursive` matches `fixtures/expected-ls.txt`.
- `cryptomako cat --local fixtures/vault /hello.txt` is exactly the fixture bytes.
- Wrong password or missing JWT → exit 1, no key material in the message.
