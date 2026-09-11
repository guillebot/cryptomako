# M2 — File Provider (not in this slice)

Read-only Finder integration after the CLI matches a Cryptomator-created fixture.

## Targets

- Host app `CryptoMako` (`net.gschimmel.cryptomako`)
- Extension `CryptoMakoFileProvider` (`net.gschimmel.cryptomako.FileProvider`)
- App Group `group.net.gschimmel.cryptomako`

## Host

1. Collect endpoint, keys, prefix, password. Password and S3 secret go to Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), access group shared with the extension.
2. Verify unlock in-process (same code as the CLI).
3. `NSFileProviderManager.add(NSFileProviderDomain(identifier: "cryptomako.\(jti)", displayName: "CryptoMako — family"))`.
4. Domain identifier is the vault JWT `jti`.

## Extension (`NSFileProviderReplicatedExtension`)

| Method | Behavior |
|--------|----------|
| `item(for:)` | Root container ↔ `d:`. Resolve `ItemId`. |
| enumerator | List via `CryptoMakoVault` + S3. |
| `fetchContents` | Download ciphertext, decrypt to the system URL, return `Progress`. |
| create/modify/delete | `NSFeatureUnsupportedError` |

`contentVersion` = S3 ETag of the ciphertext object. Files start dataless. Refresh is a menu item, not a poller.

Do not add the Xcode project until M1 passes against a real fixture.
