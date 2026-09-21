# M0 — Fixture

Goal: an S3 bucket whose plaintext you know, with the vault created by **stock Cryptomator**, not by CryptoMako.

Any S3-compatible endpoint works — a remote MinIO, AWS, Wasabi. The local container below is only for operators without a remote bucket.

## Remote bucket

Put the non-secret connection settings in `~/.config/cryptomako/poc.json`:

```json
{
  "storageMode": "s3",
  "endpoint": "https://your-minio-host:9000",
  "region": "us-east-1",
  "bucket": "your-bucket",
  "prefix": "cryptomako-poc/",
  "accessKey": "your-access-key"
}
```

Use HTTPS for the macOS app and File Provider (ATS). The CLI can still speak HTTP to a local throwaway MinIO.

Then export `CRYPTOMAKO_SECRET_KEY` and `CRYPTOMAKO_PASSWORD` and skip to "Create the vault".

Find existing vaults in a bucket with `rclone`:

```bash
rclone lsf <remote>:<bucket> -R --files-only --include "**vault.cryptomator"
```

The directory containing `vault.cryptomator` is the vault prefix. Pass it as `--prefix`.

Note that Homebrew's `mc` is GNU Midnight Commander, not the MinIO client, so `rclone` is the safer default in docs.

### Keys scoped to a single bucket

A key with no `s3:CreateBucket` permission makes `rclone` fail every upload with a
misleading `CreateBucket … AccessDenied`, because it probes for the bucket first.
Disable the probe:

```bash
export RCLONE_S3_NO_CHECK_BUCKET=true
```

CryptoMako itself never issues `CreateBucket` or `HeadBucket`, so it is unaffected.

## Local MinIO (optional)

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

Preferred for this repo: generate a format-8 fixture with the CLI (password is gitignored):

```bash
swift run cryptomako fixture
# ciphertext → fixtures/vault/
# passphrase → fixtures/PASSWORD (mode 600)
```

Then upload:

```bash
export RCLONE_S3_NO_CHECK_BUCKET=true
rclone copy fixtures/vault sch:sch-backup/cryptomako-poc/ -P
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < fixtures/PASSWORD)"
swift run cryptomako unlock --prefix cryptomako-poc/
```

If you replace an existing prefix on MinIO with a new vault (different `masterkey.cryptomator`), CryptoMako’s S3 client uses an ephemeral `URLSession` so it will not reuse a stale cached GET. Older builds that used `URLSession.shared` could keep unlocking against a cached masterkey and report a generic “unlock failed”.

The vault **password** for the uploaded ciphertext must match that vault. Uploading `fixtures/vault` means using `fixtures/PASSWORD` (Keychain `vault-password` in the app), not an older MinIO vault’s passphrase.

Stock Cryptomator desktop is still valid: create a vault locally, lock it, copy ciphertext to the same prefix. Either source must unlock in CryptoMako.

Manual Cryptomator UI steps (optional):

1. In Cryptomator desktop, create a vault in a local folder (format 8, password stored only in gitignored `fixtures/PASSWORD`).
2. Unlock and add a known tree, for example:
   - `hello.txt` = `hello cryptomako\n`
   - `notes/todo.md` = two lines
   - a small PDF or PNG under `bin/`
   - a Unicode name (`café résumé.txt`)
   - optional: a very long name to force `.c9s`
3. Lock the vault.
4. Copy the vault directory (ciphertext) into your bucket under a prefix such as `family/`:

   ```bash
   rclone copy /path/to/LocalVault <remote>:<bucket>/family/ -P
   ```

5. Record `cryptomako ls -R /` output in `fixtures/expected-ls.txt`.

Acceptance:

- The prefix contains `vault.cryptomator`, `masterkey.cryptomator`, and `d/…`.
- Stock Cryptomator can still unlock a re-download of that prefix.

The operator creates this fixture. The CLI cannot click Cryptomator’s UI.
