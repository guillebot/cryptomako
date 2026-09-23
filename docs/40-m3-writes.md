# M3 — Writes (remote-only)

CryptoMako writes exist to put Cryptomator ciphertext on **remote** object storage
(S3/MinIO). There is no local vault copy as the destination of truth.

## Success criterion

`createItem` / `modifyItem` / `deleteItem` report success to File Provider **only
after** `ObjectStore.putObject` / `deleteObject` completes on the remote store
(and PUT is verified with `headObject` where applicable).

If the remote put fails, the provider returns an error. Finder must not be told
the file is saved in the vault. Returning success without a remote put previously
allowed rclone to fill `~/Library/CloudStorage/CryptoMako-CryptoMako` with tens of
gigabytes of local-only data while MinIO still held only the fixture vault.

Local `DirectoryObjectStore` is for CLI `--local`, unit tests, and explicit Local
mode in the app window — not for File Provider mounts. The extension refuses
Local storage mode.

## Semantics

- Create folder: new UUID dirId, `Put` `dir.c9r` in the parent, `Put` `dirid.c9r`
  under `d/XX/YYY/`.
- Create/overwrite file: `encryptContent` to a temp file with a **new** header and
  nonces, then `Put` `.c9r` (or shortened `.c9s` / `name.c9s` + `contents.c9r`).
- Delete file: `Delete` ciphertext object(s).
- Delete folder: only when empty; delete `dir.c9r` + `dirid.c9r`.
- Rename: not in this slice (modifyItem metadata-only is a no-op pass-through).

## Interop gate (follow-up)

1. Create/edit/delete in Finder on an S3 vault.
2. `cryptomako ls --path / --recursive` shows the same names.
3. Download the prefix; unlock in stock Cryptomator; Directory Health Check clean.
4. Reverse: create in Cryptomator, refresh in CryptoMako.

## Bucket-scoped credentials

Never call `CreateBucket` or `HeadBucket`. Assume the bucket exists.
