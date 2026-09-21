import AppKit
import CryptoMakoS3
import CryptoMakoShared
import CryptoMakoVault
import FileProvider
import Foundation
import SwiftUI

/// Shared vault UI state for the main window and the menu-bar status item.
@MainActor
final class VaultAppModel: ObservableObject {
    enum Status: String, Equatable {
        case locked = "Locked"
        case connecting = "Connecting…"
        case unlocked = "Unlocked"
        case error = "Error"

        var color: Color {
            switch self {
            case .locked: return .secondary
            case .connecting: return .orange
            case .unlocked: return .green
            case .error: return .red
            }
        }

        /// Menu-item text color for the status row.
        var menuStatusColor: NSColor {
            switch self {
            case .locked: return .secondaryLabelColor
            case .connecting: return .systemOrange
            case .unlocked: return .systemGreen
            case .error: return .systemRed
            }
        }

        /// Colored badge on the menu-bar icon (always present).
        var statusItemIndicator: NSColor {
            switch self {
            case .locked: return .systemRed
            case .connecting: return .systemOrange
            case .unlocked: return .systemGreen
            case .error: return .systemRed
            }
        }

        var menuLabel: String {
            "Status: \(rawValue)"
        }
    }

    enum ListMode {
        case none
        case root
        case recursive
    }

    @Published var settings = VaultSettings()
    @Published var secretKey = ""
    @Published var password = ""

    @Published var status: Status = .locked
    @Published var detail = ""
    @Published var listingLines: [String] = []
    @Published var jti: String?
    @Published var busy = false
    @Published var sessionUser = ""
    @Published var sessionLocation = ""

    var bundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var isUnlocked: Bool {
        status == .unlocked
    }

    func load() {
        settings = VaultSettings.load() ?? VaultSettings()
        secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        if password.isEmpty {
            let fixturePassword = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("fixtures/PASSWORD")
            if let value = try? String(contentsOf: fixturePassword, encoding: .utf8) {
                password = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Only auto-fill the local fixture when already in Local mode (never force Local over S3).
        if settings.storageMode == .local && settings.localVaultPath.isEmpty && !bundledApp {
            let fixtureVault = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("fixtures/vault")
            if FileManager.default.fileExists(atPath: fixtureVault.appendingPathComponent("vault.cryptomator").path) {
                settings.localVaultPath = fixtureVault.path
            }
        }
        if bundledApp {
            detail = "Unlock, then Mount in Finder."
        } else {
            detail = "Running from swift run. Use a local vault or S3; Finder mount needs the signed .app."
        }
    }

    func chooseLocalVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Cryptomator vault directory (contains vault.cryptomator)."
        if panel.runModal() == .OK, let url = panel.url {
            settings.storageMode = .local
            settings.localVaultPath = url.path
        }
    }

    func save(persistSecrets: Bool = true) {
        do {
            try settings.save()
            if persistSecrets {
                if !secretKey.isEmpty {
                    try CredentialStore.saveSharedOrLocal(secretKey, account: AppIdentifiers.secretKeyAccount)
                }
                if !password.isEmpty {
                    try CredentialStore.saveSharedOrLocal(password, account: AppIdentifiers.passwordAccount)
                }
            }
            detail = "Saved. Settings are plaintext JSON; secrets are in the Keychain."
        } catch {
            status = .error
            detail = "Save failed: \(error.localizedDescription)"
        }
    }

    func resignFields() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func lock() {
        resignFields()
        status = .locked
        jti = nil
        sessionUser = ""
        sessionLocation = ""
        listingLines = []
        secretKey = ""
        password = ""
        settings = VaultSettings.load() ?? settings
        secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        detail = "Locked. Credentials are required again to unlock."
    }

    /// Menu-bar Unlock: use Keychain/form credentials; caller shows the window if this returns false.
    @discardableResult
    func unlockFromMenu() async -> Bool {
        if secretKey.isEmpty {
            secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        }
        if password.isEmpty {
            password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        }
        guard !password.isEmpty else {
            detail = "Vault password is required — open CryptoMako to unlock."
            return false
        }
        if !settings.isLocal && !settings.isComplete {
            detail = "Connection settings incomplete — open CryptoMako to configure."
            return false
        }
        if !settings.isLocal && secretKey.isEmpty {
            detail = "Secret key is required for S3 — open CryptoMako to unlock."
            return false
        }
        await unlock(listMode: .root)
        return status == .unlocked
    }

    func unlock(listMode: ListMode) async {
        busy = true
        defer { busy = false }
        status = .connecting

        if secretKey.isEmpty {
            secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        }
        if password.isEmpty {
            password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        }

        guard !password.isEmpty else {
            status = isUnlocked ? .unlocked : .locked
            detail = "Vault password is required."
            return
        }

        let snapshotSettings = settings
        let snapshotSecret = secretKey
        let snapshotPassword = password

        let store: any ObjectStore
        let location: VaultLocation
        if snapshotSettings.isLocal {
            store = DirectoryObjectStore(root: URL(fileURLWithPath: snapshotSettings.localVaultPath))
            location = VaultLocation.local(prefix: "")
        } else {
            guard snapshotSettings.isComplete, let endpoint = URL(string: snapshotSettings.endpoint) else {
                status = .error
                detail = "Endpoint, bucket, and access key are required (or choose a local vault)."
                return
            }
            guard !snapshotSecret.isEmpty else {
                status = .error
                detail = "Secret key is required for S3."
                return
            }
            store = S3ObjectStore(
                settings: S3Settings(
                    endpoint: endpoint,
                    region: snapshotSettings.region,
                    bucket: snapshotSettings.bucket,
                    accessKey: snapshotSettings.accessKey,
                    secretKey: snapshotSecret,
                    pathStyle: true
                )
            )
            location = VaultLocation(
                endpoint: endpoint,
                region: snapshotSettings.region,
                bucket: snapshotSettings.bucket,
                prefix: snapshotSettings.prefix,
                accessKey: snapshotSettings.accessKey
            )
        }

        do {
            let session = try await VaultSession.unlock(
                location: location,
                passphrase: snapshotPassword,
                store: store
            )

            var lines = [
                "format=\(session.config.format)",
                "combo=\(session.config.cipherCombo)",
                "root=\(session.rootCipherPrefix)",
                "jti=\(session.config.jti ?? "none")",
            ]

            switch listMode {
            case .none:
                break
            case .root:
                lines.append("")
                for node in try await session.list(dirId: "") {
                    lines.append(node.cleartextName + (node.kind == .directory ? "/" : ""))
                }
            case .recursive:
                lines.append("")
                let rows = try await session.listRecursive(at: "/", maxEntries: 2_000)
                for (path, node) in rows {
                    lines.append(path + (node.kind == .directory ? "/" : ""))
                }
                if rows.count >= 2_000 {
                    lines.append("… truncated at 2000 entries")
                }
            }

            do {
                try snapshotSettings.save()
                if !snapshotSecret.isEmpty {
                    try CredentialStore.saveSharedOrLocal(snapshotSecret, account: AppIdentifiers.secretKeyAccount)
                }
                if !snapshotPassword.isEmpty {
                    try CredentialStore.saveSharedOrLocal(snapshotPassword, account: AppIdentifiers.passwordAccount)
                }
            } catch {
                detail = "Unlocked, but save failed: \(error.localizedDescription)"
            }

            resignFields()
            secretKey = ""
            password = ""

            if snapshotSettings.isLocal {
                let name = URL(fileURLWithPath: snapshotSettings.localVaultPath).lastPathComponent
                sessionUser = name.isEmpty ? "local vault" : name
                sessionLocation = snapshotSettings.localVaultPath
            } else {
                sessionUser = snapshotSettings.accessKey
                let prefix = snapshotSettings.prefix.isEmpty ? "/" : snapshotSettings.prefix
                sessionLocation = "\(snapshotSettings.bucket)\(prefix.hasPrefix("/") ? "" : "/")\(prefix) @ \(snapshotSettings.endpoint)"
            }
            jti = session.config.jti
            listingLines = lines
            status = .unlocked
            if detail.hasPrefix("Unlocked, but save failed") == false {
                detail = snapshotSettings.isLocal
                    ? "Unlock succeeded (local vault)."
                    : "Unlock succeeded."
            }
        } catch {
            status = .error
            jti = nil
            sessionUser = ""
            sessionLocation = ""
            listingLines = []
            detail = error.localizedDescription
        }
        if let s3 = store as? S3ObjectStore {
            try? await s3.shutdown()
        }
    }

    func domain() -> NSFileProviderDomain? {
        guard let jti else { return nil }
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(AppIdentifiers.domainIdentifier(jti: jti)),
            displayName: "CryptoMako"
        )
    }

    func mount() async {
        guard let domain = domain() else { return }
        busy = true
        defer { busy = false }
        do {
            try await NSFileProviderManager.add(domain)
            detail = "Mounted. Look under Locations in Finder, or ~/Library/CloudStorage."
        } catch {
            status = .error
            detail = "Mount failed: \(error.localizedDescription)"
        }
    }

    func unmount() async {
        guard let domain = domain() else { return }
        busy = true
        defer { busy = false }
        do {
            try await NSFileProviderManager.remove(domain)
            detail = "Unmounted."
        } catch {
            status = .error
            detail = "Unmount failed: \(error.localizedDescription)"
        }
    }
}
