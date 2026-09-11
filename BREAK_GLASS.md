# Break-glass

Emergency procedures for a workstation running CryptoMako. There is no production service account yet.

## Vault password / S3 secret

1. Rotate the S3 access key at the bucket owner (MinIO/AWS/IAM).
2. Change the Cryptomator vault password from stock Cryptomator (or `MasterkeyFile.changePassphrase` once CryptoMako supports it).
3. Remove leftover env: `unset CRYPTOMAKO_PASSWORD CRYPTOMAKO_SECRET_KEY`.
4. Delete `~/.config/cryptomako/poc.json` if it exists (it must not contain secrets; delete it anyway).

## Keychain (M2+)

When the File Provider exists, credentials live in the macOS Keychain under the app’s access group `group.net.gschimmel.cryptomako`.

```bash
security delete-generic-password -s net.gschimmel.cryptomako 2>/dev/null || true
```

If items were stored with a different service name, open Keychain Access, search `cryptomako`, and delete matching application passwords.

## File Provider domain (M2+)

If Finder is stuck on a CryptoMako location:

1. Quit CryptoMako.
2. Remove the domain from the host app (or wait for `NSFileProviderManager.remove`).
3. Delete leftover material:

```bash
rm -rf ~/Library/CloudStorage/CryptoMako-*
killall Finder
```

4. Re-add the domain only after unlock succeeds in the CLI.

## Local MinIO fixture

```bash
docker rm -f cryptomako-minio 2>/dev/null || true
```

Bucket data is in the container; destroying the container wipes the PoC bucket unless you used a bind mount.
