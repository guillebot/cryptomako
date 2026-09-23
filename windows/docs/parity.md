# macOS â†” Windows feature parity

Checklist vs the Swift app (`Sources/CryptoMako*`) as of the Windows branch.
Legend: âœ… parity Â· ðŸŸ¡ partial / stub Â· âŒ blocked (needs Windows box or macOS-only)

| Area | macOS | Windows (.NET) | Status |
|------|-------|----------------|--------|
| Unlock local vault | âœ… | âœ… `UnlockLocal` / Desktop / CLI | âœ… |
| Unlock S3 (HTTPS SigV4) | âœ… | âœ… | âœ… |
| Browse / list (recursive) | âœ… | âœ… CLI `ls` + library | âœ… |
| Cat / get / stat | âœ… | âœ… | âœ… |
| Create dir / put file (library) | âœ… File Provider + Writes | âœ… `CreateDirectory` / `PutFile` | âœ… |
| Delete file/dir | âœ… | âœ… library + CLI | âœ… |
| Rename / move | âŒ File Provider fail-closed | âœ… library + CLI (ahead of macOS FP) | âœ… |
| CLI mkdir / put | â€” (not in Swift CLI) | âœ… `mkdir` / `put` | âœ… |
| CLI sync (Backup Sync) | app-only engine | âœ… CLI `sync` + Desktop | âœ… |
| Backup Sync engine + excludes | âœ… | âœ… size-tiered workers | âœ… |
| Settings keys (Platforms-locked) | âœ… | âœ… same JSON keys | âœ… |
| Proxy (system/direct/custom) | âœ… | âœ… | âœ… |
| Credentials store | Keychain | Cred Manager (Win) / env+secrets.json (Mac host) + `cred` CLI | âœ… |
| Tray / status item | âœ… NSStatusItem | âœ… Avalonia `TrayIcon` | ðŸŸ¡ |
| Tray unlock / lock / open / quit | âœ… | âœ… | âœ… |
| Connectivity probe lamps | TCP-focused + banner | dns/tcp/https/list + tray labels | âœ… |
| autoReconnect monitor | âœ… 20s + launch unlock | âœ… 20s + launch/preference unlock | âœ… |
| Finder File Provider | âœ… | â€” | âŒ CfAPI on Windows box |
| Explorer CfAPI mount | — | WinRT SyncRootManager + recursive placeholders + hydrate; delete/rename fail-closed ACK | partial |
| FUSE / rclone path | âœ… optional | â€” (not applicable) | âŒ N/A |
| Update checker | âœ… | â€” | ðŸŸ¡ deferred |
| Transfer metrics in menu | âœ… | â€” | ðŸŸ¡ deferred |
| WinUI / MSIX installer | â€” | ðŸŸ¡ publish notes only | âŒ Windows box |
| Golden fixture tests | âœ… | âœ… + mutation tests | âœ… |

## Remaining for a Windows box

1. **Live CfAPI** — WinRT SyncRootManager + recursive populate + hydrate smoked; wire durable delete/rename after remote 2xx; confirm Explorer cloud glyph in UI.
2. **Tray on Windows** â€” confirm NotifyIcon behavior (Avalonia already implemented; smoke on Win).
3. **Credential Manager** â€” `cred set/get` against real Windows vault (Mac host uses env/file).
4. **`dotnet publish -r win-x64`** package smoke + optional MSIX later (see `docs/packaging.md`).
5. **WinUI shell** (optional) â€” Avalonia is the cross-platform host until then.

Do **not** treat Mac builds of `CryptoMako.CfApi` as a working Explorer mount.

