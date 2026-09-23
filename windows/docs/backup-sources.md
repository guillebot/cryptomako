# Backup sources (Windows)

Windows keeps the backup-sources list in a **local** file:

`%AppData%/CryptoMako/backup-sources.json`

This is **not** `settings.json`. Field names mirror the Mac mental model already in use:

| Field | Meaning |
|-------|---------|
| `id` | Stable GUID |
| `path` | Absolute cleartext folder on disk |
| `vaultFolderName` | Folder name under `Backups/` inside the vault |
| `addedAt` | UTC timestamp when added |

No new Platforms-locked settings keys are introduced here (schedule keys, etc. wait for the Settings PR).

## Nested / overlapping paths (Platforms consensus)

Resolved with `Path.GetFullPath` plus final symlink/junction target when the OS can resolve it.

1. **Add (soft-warn):** adding a source whose resolved path is the same as, or a prefix of, another listed source logs a warning and still persists the add.
2. **Sync (hard-fail):** Sync refuses to start if any pair of sources overlaps. Fix the list, then retry.

CLI one-shot `--source` / desktop single-path fallback is treated as a one-element set (no overlap possible).

## Remote-change probe (read-only)

While unlocked, connectivity probe / Probe S3 also HEADs `vault.cryptomator` and compares an ETag\|size fingerprint captured at unlock.

On change, UI/status shows **remote changed — remount/refresh**. There is **no merge policy** and **no new shared settings key** (poll stays tied to the existing probe loop).
