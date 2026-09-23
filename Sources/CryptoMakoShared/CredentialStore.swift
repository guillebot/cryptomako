import Foundation
import Security

/// Keychain-backed storage for the two secrets, shared between the host app and
/// the File Provider extension via a keychain access group.
///
/// Uses the **data-protection Keychain** (`kSecUseDataProtectionKeychain`).
/// Access is entitlement-based (keychain-access-groups), not code-signature ACL,
/// so Debug rebuilds no longer spam "Always Allow" for CryptoMakoFileProvider.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never syncs to iCloud
/// Keychain; readable once the Mac has unlocked after boot (needed for the
/// File Provider, which may run before a GUI session is fully up).
public enum CredentialStore {
    public enum StoreError: Error, LocalizedError {
        case unhandled(OSStatus)
        case notFound

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "credential not found in keychain"
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            }
        }
    }

    public static func save(_ value: String, account: String, useAccessGroup: Bool = true) throws {
        // Drop any classic (ACL) copy so we do not keep prompting on old items.
        deleteClassic(account: account, useAccessGroup: useAccessGroup)
        var query = baseQuery(account: account, useAccessGroup: useAccessGroup)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.unhandled(status)
        }
    }

    public static func read(account: String, useAccessGroup: Bool = true) throws -> String {
        var query = baseQuery(account: account, useAccessGroup: useAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            // One-shot migration from pre-DP classic Keychain items.
            if let migrated = try? readClassic(account: account, useAccessGroup: useAccessGroup) {
                try? save(migrated, account: account, useAccessGroup: useAccessGroup)
                return migrated
            }
            throw StoreError.notFound
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw StoreError.unhandled(status)
        }
        return value
    }

    /// Unsigned SwiftPM builds have no `keychain-access-groups` entitlement and
    /// fail with `errSecMissingEntitlement`; fall back to an unshared item so the
    /// CLI and `swift run` GUI still work before a signing identity exists.
    public static func saveSharedOrLocal(_ value: String, account: String) throws {
        do {
            try save(value, account: account, useAccessGroup: true)
        } catch {
            try save(value, account: account, useAccessGroup: false)
        }
    }

    public static func readSharedOrLocal(account: String) throws -> String {
        if let shared = try? read(account: account, useAccessGroup: true) {
            return shared
        }
        return try read(account: account, useAccessGroup: false)
    }

    public static func delete(account: String, useAccessGroup: Bool = true) {
        SecItemDelete(baseQuery(account: account, useAccessGroup: useAccessGroup) as CFDictionary)
        deleteClassic(account: account, useAccessGroup: useAccessGroup)
    }

    // MARK: - Data-protection queries

    private static func baseQuery(account: String, useAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentifiers.keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        // Unsigned SwiftPM builds have no entitlement, so an access group would fail.
        if useAccessGroup {
            query[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        return query
    }

    // MARK: - Classic (ACL) Keychain — migrate away; causes Always Allow spam

    private static func classicQuery(account: String, useAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentifiers.keychainService,
            kSecAttrAccount as String: account,
        ]
        if useAccessGroup {
            // Old builds used the bare group id; try both.
            query[kSecAttrAccessGroup as String] = "group.net.gschimmel.cryptomako"
        }
        return query
    }

    private static func readClassic(account: String, useAccessGroup: Bool) throws -> String {
        for group in classicAccessGroupVariants(useAccessGroup: useAccessGroup) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AppIdentifiers.keychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let group {
                query[kSecAttrAccessGroup as String] = group
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8)
            {
                deleteClassic(account: account, useAccessGroup: useAccessGroup)
                return value
            }
        }
        throw StoreError.notFound
    }

    private static func deleteClassic(account: String, useAccessGroup: Bool) {
        for group in classicAccessGroupVariants(useAccessGroup: useAccessGroup) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AppIdentifiers.keychainService,
                kSecAttrAccount as String: account,
            ]
            if let group {
                query[kSecAttrAccessGroup as String] = group
            }
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func classicAccessGroupVariants(useAccessGroup: Bool) -> [String?] {
        if useAccessGroup {
            return [
                AppIdentifiers.keychainAccessGroup,
                "group.net.gschimmel.cryptomako",
            ]
        }
        return [nil]
    }
}
