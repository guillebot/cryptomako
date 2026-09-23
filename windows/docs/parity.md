# macOS ? Windows feature parity

Checklist vs the Swift app (`Sources/CryptoMako*`) as of the Windows branch.
Legend: ? parity ? ? partial / stub ? ? blocked (needs Windows box or macOS-only)

| Area | macOS | Windows (.NET) | Status |
|------|-------|----------------|--------|
| Unlock local vault | ? | ? `UnlockLocal` / Desktop / CLI | ? |
| Unlock S3 (HTTPS SigV4) | ? | ? | ? |
| Browse / list (recursive) | ? | ? CLI `ls` + library | ? |
| Cat / get / stat | ? | ? | ? |
| Create dir / put file (library) | ? File Provider + Writes | ? `CreateDirectory` / `PutFile` | ? |
| Delete file/dir | ? | ? library + CLI + CfAPI NOTIFY | ? |
| Rename / move | ? File Provider fail-closed | ? library + CLI + CfAPI NOTIFY | ? |
| CLI mkdir / put | ? (not in Swift CLI) | ? `mkdir` / `put` | ? |
| CLI sync (Backup Sync) | app-only engine | ? CLI `sync` + Desktop | ? |
| Backup Sync engine + excludes | ? | ? size-tiered workers | ? |
| Settings keys (Platforms-locked) | ? | ? same JSON keys | ? |
| Proxy (system/direct/custom) | ? | ? | ? |
| Credentials store | Keychain | Cred Manager (Win) / env+secrets.json (Mac host) + `cred` CLI | ? |
| Tray / status item | ? NSStatusItem | ? Avalonia `TrayIcon` | ? |
| Tray unlock / lock / open / quit | ? | ? | ? |
| Connectivity probe lamps | TCP-focused + banner | dns/tcp/https/list + tray labels | ? |
| autoReconnect monitor | ? 20s + launch unlock | ? 20s + launch/preference unlock | ? |
| Finder File Provider | ? | ? | ? CfAPI on Windows |
| Explorer CfAPI soft viewer | ? | register/connect/populate/hydrate; NOTIFY delete/rename fail-closed; CLOSE write-back; FETCH_PLACEHOLDERS; refresh-dir | ? soft |
| FUSE / rclone path | ? optional | ? (not applicable) | ? N/A |
| Update checker | ? | ? | ? deferred |
| Transfer metrics in menu | ? | ? | ? deferred |
| WinUI / MSIX installer | ? | ? publish folder only | ? deferred |
| Golden fixture tests | ? | ? + mutation / CfAPI unit tests | ? |

## Soft release (Windows side)

**Ready** for soft release when the above soft surfaces are green: unlock, Backup Sync, Platforms-locked settings, CredMan, tray, CLI, and **soft** Explorer CfAPI viewer (not full Finder-FP multi-device sync safety).

Smoked on monster (Win11): CredMan `cred set/get/delete`, `cfapi platform` supported, soft CfAPI mount path exercised in prior PR commits.

## Deferred (not soft-release blockers)

1. Conflict/merge / remote-change watcher (see `docs/cfapi.md`).
2. Forget-credentials / CredMan wipe on Lock (Lock = in-process clear only).
3. CLOSE fail cannot deny; dirty local bytes on failed write-back.
4. Update checker, transfer metrics menu, WinUI/MSIX.
5. WinRT `GetCurrentSyncRoots` empty on some hosts while Cf+registry still provides Explorer awareness.

Do **not** treat Mac builds of `CryptoMako.CfApi` as a working Explorer mount.

## Soft-parity closeout (Windows)

| Gap | Resolution |
|-----|------------|
| Lock High order (cancel Backup Sync → disconnect CfAPI viewer; no CredMan wipe) | Shipped |
| Soft CfAPI `ExplorerViewer` binding on connect | Shipped — Desktop auto-binds on unlock; CLI `cfapi connect` binds a host VM; Lock clears binding |
| Unlock / ls / cat / Backup Sync / CredMan / HTTPS-only / settings keys / tray probes | Shipped (soft bar) |
| Remote-change conflict watcher | **Deferred** — see below |
| CredMan wipe on Lock / Forget credentials | **Deferred** (Platforms) |
| App Store / installer polish | **Deferred** |

### Conflict watcher — Platforms-ready deferral

No merge engine and **no new shared settings keys** in this soft bar.

**Intent (when Platforms approves):** a read-only probe (e.g. vault `vault.cryptomator` / root dir ETag or mtime) while the soft viewer is connected; on change, surface a non-blocking “remote changed — remount/refresh” status (no auto-merge, no conflict copies). Poll interval / enablement would need Platforms-approved keys if not hard-coded.

Until then Windows soft release remains single-writer / last-writer-wins at the object store, matching the CfAPI CLOSE write-back policy in `cfapi.md`.

