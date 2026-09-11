# M2 — File Provider

Read-only Finder integration. Scaffolded and building; not yet running as a
registered domain (see *Blockers*).

## Targets

The Xcode project is **generated**, not committed — `project.yml` is the source
of truth and `*.xcodeproj` is gitignored.

```bash
xcodegen generate
open CryptoMako.xcodeproj
```

| Target | Bundle ID | Sources |
|--------|-----------|---------|
| App `CryptoMako` | `net.gschimmel.cryptomako` | `Sources/CryptoMakoApp` |
| Extension `CryptoMakoFileProvider` | `net.gschimmel.cryptomako.FileProvider` | `Sources/CryptoMakoFileProvider` |
| App Group | `group.net.gschimmel.cryptomako` | — |

Both link the local SwiftPM products `CryptoMakoVault`, `CryptoMakoS3`, and
`CryptoMakoShared`. The extension sources are also a plain SwiftPM target so
`swift build` type-checks them without Xcode.

## Unsigned development (no Apple Developer Program)

A Finder mount is not reachable without a paid Team ID. This was tested rather
than assumed, because the failure mode is misleading — see *What ad-hoc signing
does and does not buy* below. Until then:

```bash
cryptomako fixture
export CRYPTOMAKO_PASSWORD="$(tr -d '\n' < fixtures/PASSWORD)"
cryptomako ls --local fixtures/vault --path / --recursive
cryptomako get --local fixtures/vault /hello.txt --output /tmp/hello.txt
swift run CryptoMakoApp   # prefills fixtures/vault + fixtures/PASSWORD
```

The SwiftUI window hides **Mount in Finder** when it is not running from a `.app` bundle. Unlock and listing work against a local vault or S3.

`swift test` covers the vault, SigV4, and identifier logic without any of this.

Compile check without a signing identity:

```bash
xcodebuild -project CryptoMako.xcodeproj -scheme CryptoMako \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Host

The host is a real windowed app, not a hidden helper:

1. Edit endpoint, region, bucket, prefix, access key. `VaultSettings.save()`
   writes both the app-group container (the only place the sandboxed extension
   can read) and `~/.config/cryptomako/poc.json` (CLI parity).
2. Secret key and vault password go to the Keychain via `CredentialStore`,
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, in a shared access group.
   Never to `poc.json`.
3. Unlock in-process using the same `VaultSession` as the CLI, showing format,
   `cipherCombo`, `jti`, and the root ciphertext prefix.
4. **Mount in Finder** → `NSFileProviderManager.add(domain)`.
   Domain identifier is `cryptomako.<jti>`.

## Extension (`NSFileProviderReplicatedExtension`)

| Method | Behavior |
|--------|----------|
| `item(for:)` | Root ↔ `.rootContainer`; `d:`/`f:` resolved via `VaultIndex` |
| `enumerator(for:)` | `VaultEnumerator` lists one directory through `CryptoMakoVault` |
| `fetchContents` | Downloads ciphertext, decrypts file-to-file, returns a `Progress` |
| create/modify/delete | `NSFeatureUnsupportedError` until M3 |

`contentVersion` is the S3 ETag: it changes exactly when the bytes change. Files
start dataless. `enumerateChanges` reports nothing — refresh is host-driven, not
a poller.

Every async entry point returns a real `Progress` with a cancellation handler.
Without one the system can cancel a slow request out from under the extension.

## What ad-hoc signing does and does not buy

Measured on macOS 26.6 / Xcode 16.4 with zero signing identities, against an
ad-hoc signed build. The interesting part is how far it gets before failing.

Works ad-hoc, no Apple ID:

- Building and signing both the app and the `.appex`.
- `pluginkit` registration — the extension is listed under
  `com.apple.fileprovider-nonui`.
- `NSFileProviderManager.add(domain)` returns success.
- `getUserVisibleURL` returns a path, and macOS creates
  `~/Library/CloudStorage/CryptoMako-<domain>` next to Nextcloud and OneDrive.

Then it stops. The extension is never launched, so every request against that
folder hangs and `ls` eventually reports `fts_read: Operation timed out`. There
is no error, no crash report, and nothing in the log, because the domain and the
process that serves it are registered independently. **A domain that registers is
not evidence that anything works.**

Three separate requirements, each of which produces that same silent hang:

1. **The extension must be sandboxed.** `pluginkit` refuses to register an
   unsandboxed File Provider, while `add` keeps succeeding.
2. **`ENABLE_DEBUG_DYLIB` must be off.** Xcode 16 debug builds emit a stub
   binary plus `*.debug.dylib` and `__preview.dylib`; the system will not launch
   an appex in that shape. Now set in the base settings so it applies to signed
   debug builds too.
3. **The App Group must exist and be team-prefixed.** This is the hard stop.
   `com.apple.security.application-groups` fails the build with *"requires a
   provisioning profile"* even under `CODE_SIGN_STYLE: Manual` with an ad-hoc
   identity, and the group must carry the team prefix. Both shipping providers
   on a stock Mac confirm the shape: Nextcloud uses
   `NKUJUXUJ3B.com.nextcloud.desktopclient`, OneDrive
   `UBF8T346G9.OneDriveStandaloneSuite`.

There is no way to satisfy (3) without enrolling. (1) and (2) are already fixed
in the shipping configuration; an ad-hoc build configuration was tried and then
dropped, because one that registers a domain it cannot serve is a trap.

Useful commands while debugging this:

```bash
pluginkit -mv | grep -i cryptomako          # is the appex registered, and from where?
codesign -d --entitlements :- <path>.appex  # what did it actually get signed with?
log show --last 5m --predicate 'subsystem == "net.gschimmel.cryptomako"' --info --debug
```

## Blockers

**No code-signing identity.** `security find-identity -v -p codesigning` returns
zero. Per the section above, the App Group is the blocking capability, so
enrolling in the Apple Developer Program and setting `DEVELOPMENT_TEAM` in
`project.yml` is the only path to a working mount. Required anyway to ship a
Developer ID–signed, notarized app.

**`AppIdentifiers.appGroup` is not team-prefixed yet.** The entitlements and
`NSExtensionFileProviderDocumentGroup` use `$(AppIdentifierPrefix)`, which the
build expands. The Swift constant cannot, so it needs the literal team ID once
that exists, or `containerURL(forSecurityApplicationGroupIdentifier:)` returns
nil at runtime.

**App Transport Security vs plain-HTTP endpoints.** A bare CLI binary is not
ATS-constrained, which is why `http://…:9000` works today. The sandboxed app and
extension *are*. Options, best first:

1. Terminate TLS in front of MinIO and use `https://`.
2. Add a narrow `NSExceptionDomains` entry for that one host.
3. `NSAllowsArbitraryLoads` — what most S3 clients do, and a real reduction in
   transport security. Do not add it without an explicit decision.

None is in the plists yet; the default is HTTPS-only.

**SDK skew.** Xcode 16.4 ships the macOS 15.5 SDK on a macOS 26 host. It builds,
but debug File Provider behavior against Tahoe with Xcode 26.

## Verification once signed

1. Unlock in the host app, then **Mount in Finder**.
2. `~/Library/CloudStorage/` shows the domain; the vault tree lists.
3. Opening a file hydrates it and the contents match `cryptomako cat`.
4. Writes fail cleanly rather than corrupting the vault.
