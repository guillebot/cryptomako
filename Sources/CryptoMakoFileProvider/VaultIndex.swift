import CryptoMakoS3
import CryptoMakoShared
import CryptoMakoVault
import FileProvider
import Foundation
import OSLog

/// The extension has no console of its own; `log stream --predicate
/// 'subsystem == "net.gschimmel.cryptomako"'` is the only practical way to see
/// why an unlock failed, since every failure has to surface as `notAuthenticated`.
let log = Logger(subsystem: "net.gschimmel.cryptomako", category: "fileprovider")

/// Owns the unlocked `VaultSession` and a `DirectoryIndex`.
actor VaultIndex {
    private var cachedSession: VaultSession?
    private var index: DirectoryIndex?

    func session() async throws -> VaultSession {
        if let cachedSession {
            return cachedSession
        }
        let unlocked = try await unlock()
        cachedSession = unlocked
        index = DirectoryIndex(session: unlocked)
        return unlocked
    }

    /// Drop listing cache only. Keep the unlocked session so we do not re-hit
    /// Keychain / S3 unlock after every create/modify/delete.
    func invalidateListing() {
        index = nil
    }

    /// Full teardown (domain tear-down / lock). Clears session and listings.
    func invalidate() {
        cachedSession = nil
        index = nil
    }

    func children(of dirId: String) async throws -> [VaultNode] {
        try await directoryIndex().children(of: dirId)
    }

    func directoryInfo(dirId: String, hintParent: String? = nil) async throws -> DirectoryIndex.DirInfo? {
        try await directoryIndex().directoryInfo(dirId: dirId, hintParent: hintParent)
    }

    func file(parentDirId: String, cipherName: String) async throws -> VaultNode? {
        try await directoryIndex().file(parentDirId: parentDirId, cipherName: cipherName)
    }

    private func directoryIndex() async throws -> DirectoryIndex {
        let unlocked = try await session()
        if let index {
            return index
        }
        let rebuilt = DirectoryIndex(session: unlocked)
        index = rebuilt
        return rebuilt
    }

    /// Reads the passphrase from the Keychain access group shared with the host app.
    private func vaultPassword() throws -> String {
        guard let value = try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount),
              !value.isEmpty
        else {
            log.error("no vault password available")
            throw NSFileProviderError(.notAuthenticated)
        }
        return value
    }

    private func unlock() async throws -> VaultSession {
        guard let settings = VaultSettings.load() else {
            log.error("no settings at \(VaultSettings.cliConfigURL.path, privacy: .public)")
            throw NSFileProviderError(.notAuthenticated)
        }
        let password = try vaultPassword()

        // Product File Provider is remote-only. Local mode is for CLI/tests — mounting
        // a local vault would encourage CloudStorage materialization as if it were the vault.
        if settings.isLocal {
            log.error("File Provider refuses Local storage mode (remote-only product)")
            throw NSFileProviderError(.notAuthenticated)
        }

        guard settings.isComplete, let endpoint = URL(string: settings.endpoint) else {
            log.error("settings incomplete for S3")
            throw NSFileProviderError(.notAuthenticated)
        }
        let secretKey: String
        do {
            secretKey = try CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)
        } catch {
            log.error("no S3 secret key available")
            throw NSFileProviderError(.notAuthenticated)
        }
        let netPrefs = AppPreferences.load()
        let proxyPassword = try? CredentialStore.readSharedOrLocal(
            account: AppIdentifiers.proxyPasswordAccount
        )
        let store = S3ObjectStore(
            settings: S3Settings(
                endpoint: endpoint,
                region: settings.region,
                bucket: settings.bucket,
                accessKey: settings.accessKey,
                secretKey: secretKey,
                pathStyle: true
            ),
            configureSession: { netPrefs.applyProxy(to: $0, password: proxyPassword) }
        )
        let location = VaultLocation(
            endpoint: endpoint,
            region: settings.region,
            bucket: settings.bucket,
            prefix: settings.prefix,
            accessKey: settings.accessKey
        )
        do {
            return try await VaultSession.unlock(location: location, passphrase: password, store: store)
        } catch {
            log.error("S3 unlock failed: \(error.localizedDescription, privacy: .public)")
            throw NSFileProviderError(.notAuthenticated)
        }
    }
}
