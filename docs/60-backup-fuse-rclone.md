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
- [x] Nested/overlapping sources: soft-warn on add, hard-fail on Sync all / rclone
- [x] SMB Backup sources: explicit smb:// add, NetFS remount, Keychain, fail-closed

## Backup tab usage

1. Unlock the vault (S3).
2. **Mount sync volume** → `/Volumes/CryptoMakoSync`.
3. Add folders, then **Sync direct** (no FUSE) or **Sync via rclone+FUSE**.
4. Confirm menu-bar transfer metrics and MinIO objects under `Backups/` (direct) or vault paths written through FUSE.

Host app links `/Library/Frameworks/macFUSE.framework` via ObjC only (Swift does not import the incompatible `macFUSE` Swift module).


## Nested / overlapping Backup sources (Platforms consensus)

Resolved with `URL.resolvingSymlinksInPath` + `standardizedFileURL` (absolute path spirit matches Windows `GetFullPath` + final symlink/junction target).

1. **Add (soft-warn):** adding a source whose resolved path is the same as, or a prefix of, another listed source sets the Backup status line to a warning and **still persists** the add.
2. **Sync (hard-fail):** **Sync all** and **Sync via rclone+FUSE** refuse to start if any pair of sources overlaps. Fix the list, then retry. Single-source Sync is a one-element set (no overlap possible).

No new shared settings keys. Logic lives in `CryptoMakoShared.BackupPathOverlap` (parity with Windows `BackupPathOverlap`).

Unit tests: `Tests/CryptoMakoVaultTests/BackupPathOverlapTests.swift`.

### Manual check (UI)

1. Add `/tmp/cm-parent`, then add `/tmp/cm-parent/child` → status warns about nested overlap; both remain listed.
2. Unlock + **Sync all** → status shows “Backup Sync refused…” and no upload starts.
3. Remove one of the nested sources → Sync all proceeds.


## SMB Backup sources (macOS)

Architecture (locked): **no embedded SMB client** (no libsmbclient). CryptoMako uses macOS mounts under `/Volumes` via **NetFS** (fallback `mount_smbfs`), persists a **security-scoped bookmark** + `smb://` URL in `backup-sources.json`, and stores the password in **Keychain** (`smb-password-<source-id>`).

| Step | Behavior |
|------|----------|
| **Add SMB share…** | URL `smb://server/share[/path]`, optional username, password → mount → bookmark → Keychain → list as source with SMB badge |
| **Before Sync** | Remount-on-demand (`ensureMounted`: bookmark → existing `/Volumes` → NetFS) |
| **Unavailable at start** | Sync **fails closed** with a clear error (never silent skip / empty-tree wipe) |
| **Volume drops mid-Sync** | Sync **cancels/fails closed** (`BackupSyncEngine` probes every ~200 entries + after each source) |
| **Remove source** | Deletes Keychain secret; does **not** force-unmount (user may have mounted outside the app) |
| **Lock/quit** | Password never kept in plaintext UI state after add; Keychain only |

Folder-picker sources remain unchanged. Overlap soft-warn / Sync hard-fail still apply once mounted paths are known.

Unit tests: `Tests/CryptoMakoVaultTests/SMBSourceURLTests.swift` (URL normalize + Codable migration). Smoke-test remount with a real share on Guillermo's Mac.
