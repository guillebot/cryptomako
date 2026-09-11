import Foundation
import Security

/// Keychain-backed storage for the two secrets, shared between the host app and
/// the File Provider extension via a keychain access group.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: these must never sync to
/// iCloud Keychain and must not be readable while the Mac is locked.
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
        var query = baseQuery(account: account, useAccessGroup: useAccessGroup)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
    }

    private static func baseQuery(account: String, useAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentifiers.keychainService,
            kSecAttrAccount as String: account,
        ]
        // Unsigned SwiftPM builds have no entitlement, so an access group would fail.
        if useAccessGroup {
            query[kSecAttrAccessGroup as String] = AppIdentifiers.keychainAccessGroup
        }
        return query
    }
}
