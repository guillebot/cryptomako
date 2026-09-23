# Backup sync (FUSE + rclone) vs Finder viewer

## Why the split

File Provider CloudStorage **materializes full file bytes locally** before remote
puts finish. Bulk `rclone copy` into the Finder mount fills the SSD and reports
local speed, not MinIO bandwidth.

## Architecture

| Surface | Role |
|---------|------|
| **Backup tab** | Pick local folders; Sync Now |
| **Direct sync engine** | Walk sources → Cryptomator encrypt → S3 put (bounded parallel; large files serialized) |
| **macFUSE mount** (`/Volumes/CryptoMakoSync`) | Cleartext vault FS for tools; write blocks until remote put |
| **rclone** | Copy/sync into the FUSE mount (filters, progress, resume) |
| **File Provider** | Finder **viewer** + small ad-hoc transfers only |

## Rules

- Never point rclone at `~/Library/CloudStorage/CryptoMako-*` for bulk backup.
- Never mount FUSE *inside* the File Provider domain (Finder deadlock).
- Ciphertext stays on S3 only; FUSE presents **cleartext**, CryptoMako encrypts.
- Product doc “no FUSE for ciphertext” still holds — this FUSE is not Cryptomator-on-S3-ciphertext.

## Status

- [x] Folder picker + persisted sources
- [x] Direct Sync Now via VaultSession
- [x] Cleartext macFUSE filesystem (`VaultFuseDelegate` + `CryptoMakoFuseHost` ObjC bridge)
- [x] rclone driver targeting `/Volumes/CryptoMakoSync` (absolute Homebrew path; host app sandbox off)

## Backup tab usage

1. Unlock the vault (S3).
2. **Mount sync volume** → `/Volumes/CryptoMakoSync`.
3. Add folders, then **Sync direct** (no FUSE) or **Sync via rclone+FUSE**.
4. Confirm menu-bar transfer metrics and MinIO objects under `Backups/` (direct) or vault paths written through FUSE.

Host app links `/Library/Frameworks/macFUSE.framework` via ObjC only (Swift does not import the incompatible `macFUSE` Swift module).
