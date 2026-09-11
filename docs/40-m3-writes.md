# M3 — Writes (not in this slice)

Implement `createItem`, `modifyItem`, `deleteItem` on the File Provider only after read-only hydration is boring.

## Semantics

- Create folder: new UUID dirId, `Put` `dir.c9r` in the parent, `Put` `dirid.c9r` backup when format 8 expects it.
- Create/overwrite file: `encryptContent` to a temp file with a **new** header and nonces, then `Put` `.c9r` (multipart if larger than 8 MiB).
- Rename file: copy ciphertext object + delete.
- Rename folder: rewrite the parent name / `dir.c9r` only. Do not copy `d/XX/YYY`.

## Interop gate

1. Create/edit/rename/delete in Finder.
2. Download the prefix; unlock in stock Cryptomator.
3. Directory Health Check → zero warnings for CryptoMako operations.
4. Reverse: create a file in Cryptomator, Refresh in CryptoMako, file appears.

Conflicts: last-writer-wins with `If-Match` ETag when the endpoint supports it.
