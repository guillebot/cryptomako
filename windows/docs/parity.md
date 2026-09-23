# macOS ↔ Windows feature parity

Checklist vs the Swift app (`Sources/CryptoMako*`) as of the Windows branch.
Legend: ✅ parity · 🟡 partial / stub · ❌ blocked (needs Windows box or macOS-only)

| Area | macOS | Windows (.NET) | Status |
|------|-------|----------------|--------|
| Unlock local vault | ✅ | ✅ `UnlockLocal` / Desktop / CLI | ✅ |
| Unlock S3 (HTTPS SigV4) | ✅ | ✅ | ✅ |
| Browse / list (recursive) | ✅ | ✅ CLI `ls` + library | ✅ |
| Cat / get / stat | ✅ | ✅ | ✅ |
| Create dir / put file (library) | ✅ File Provider + Writes | ✅ `CreateDirectory` / `PutFile` | ✅ |
| Delete file/dir | ✅ | ✅ library + CLI | ✅ |
| Rename / move | ❌ File Provider fail-closed | ✅ library + CLI (ahead of macOS FP) | ✅ |
| CLI mkdir / put | — (not in Swift CLI) | ✅ `mkdir` / `put` | ✅ |
| CLI sync (Backup Sync) | app-only engine | ✅ CLI `sync` + Desktop | ✅ |
| Backup Sync engine + excludes | ✅ | ✅ size-tiered workers | ✅ |
| Settings keys (Platforms-locked) | ✅ | ✅ same JSON keys | ✅ |
| Proxy (system/direct/custom) | ✅ | ✅ | ✅ |
| Credentials store | Keychain | Cred Manager (Win) / env+secrets.json (Mac host) + `cred` CLI | ✅ |
| Tray / status item | ✅ NSStatusItem | ✅ Avalonia `TrayIcon` | 🟡 |
| Tray unlock / lock / open / quit | ✅ | ✅ | ✅ |
| Connectivity probe lamps | TCP-focused + banner | dns/tcp/https/list + tray labels | ✅ |
| autoReconnect monitor | ✅ 20s + launch unlock | ✅ 20s + launch/preference unlock | ✅ |
| Finder File Provider | ✅ | — | ❌ CfAPI on Windows box |
| Explorer CfAPI mount | — | 🟡 Connect+placeholder+hydrate live; WinRT glyph stub | 🟡 |
| FUSE / rclone path | ✅ optional | — (not applicable) | ❌ N/A |
| Update checker | ✅ | — | 🟡 deferred |
| Transfer metrics in menu | ✅ | — | 🟡 deferred |
| WinUI / MSIX installer | — | 🟡 publish notes only | ❌ Windows box |
| Golden fixture tests | ✅ | ✅ + mutation tests | ✅ |

## Remaining for a Windows box

1. **Live CfAPI** — register sync root, placeholders, Explorer browse; validate fail-closed puts.
2. **Tray on Windows** — confirm NotifyIcon behavior (Avalonia already implemented; smoke on Win).
3. **Credential Manager** — `cred set/get` against real Windows vault (Mac host uses env/file).
4. **`dotnet publish -r win-x64`** package smoke + optional MSIX later (see `docs/packaging.md`).
5. **WinUI shell** (optional) — Avalonia is the cross-platform host until then.

Do **not** treat Mac builds of `CryptoMako.CfApi` as a working Explorer mount.
