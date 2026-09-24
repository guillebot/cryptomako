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


## Destination path scheme (source prefix)

Each source root contributes a stable cleartext prefix under `Backups/{vaultFolderName}/`:

| Local source | VaultFolder UI (host) | Destination root |
|---|---|---|
| `C:\Users\guill` | `MONSTER` (hostname default) | `Backups/MONSTER/Users/guill/` |
| `D:\Projects` | `MONSTER` | `Backups/MONSTER/Projects/` |
| `C:\Users\guill` | _(empty / null)_ | `Backups/Users/guill/` |
| `C:\Users\guill` | `guill` (Mac-style leaf) | `Backups/guill/` (no double prefix) |

- **Prefix rule:** when the source root **is** the user profile (`.../Users/{name}` or `.../home/{name}`) -> `Users/{name}`; otherwise last path segment (`Documents`, `Projects`, ...).
- **Compose:** host label + `/` + prefix when the stored name does not already end with the source leaf/prefix.
- **Mac parity:** macOS namespaces via `vaultFolderName = lastPathComponent` per source (no hostname default). Windows keeps the hostname default and nests the source prefix under it so multiple sources on one host do not mix.
- **Soft migration:** on Desktop load/Sync, bare host folders (e.g. stored `MONSTER` for `C:\Users\guill`) are rewritten to `MONSTER/Users/guill` in `backup-sources.json`. Already-synced vault objects under the bare host folder are **left in place** (not wiped). Sync state keys follow the new folder, so files re-upload under the prefixed path; old cleartext under `Backups/MONSTER/` remains until manually cleaned.
