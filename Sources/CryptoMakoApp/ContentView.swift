import AppKit
import CryptoMakoS3
import CryptoMakoShared
import CryptoMakoVault
import FileProvider
import SwiftUI

struct ContentView: View {
    @State private var settings = VaultSettings()
    @State private var secretKey = ""
    @State private var password = ""

    @State private var status = Status.locked
    @State private var detail = ""
    @State private var listingLines: [String] = []
    @State private var jti: String?
    @State private var busy = false
    @State private var sessionUser = ""
    @State private var sessionLocation = ""

    private var bundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var isUnlocked: Bool {
        status == .unlocked
    }

    enum Status: String {
        case locked = "Locked"
        case working = "Working…"
        case unlocked = "Unlocked"

        var color: Color {
            switch self {
            case .locked: return .secondary
            case .working: return .orange
            case .unlocked: return .green
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isUnlocked {
                sessionBanner
            } else {
                credentialsForm
            }
            controls
            Text(detail)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            listingView
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CryptoMako").font(.title)
                    Spacer()
                    Text(status.rawValue)
                        .font(.headline)
                        .foregroundStyle(status.color)
                }
                if isUnlocked {
                    Text("Signed in as \(sessionUser)")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("A Cryptomator format-8 vault, decrypted in-process.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionUser)
                    .font(.headline)
                Text(sessionLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Lock") { lock() }
                .disabled(busy)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var credentialsForm: some View {
        Form {
            TextField("Local vault directory", text: $settings.localVaultPath)
            HStack {
                Button("Choose…") { chooseLocalVault() }
                Text("Leave empty to use S3.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            TextField("Endpoint", text: $settings.endpoint)
                .disabled(settings.isLocal)
            TextField("Region", text: $settings.region)
                .disabled(settings.isLocal)
            TextField("Bucket", text: $settings.bucket)
                .disabled(settings.isLocal)
            TextField("Prefix", text: $settings.prefix)
                .disabled(settings.isLocal)
            TextField("Access key", text: $settings.accessKey)
                .disabled(settings.isLocal)
            SecureField("Secret key", text: $secretKey)
                .disabled(settings.isLocal)
            SecureField("Vault password", text: $password)
        }
    }

    private var controls: some View {
        HStack {
            if !isUnlocked {
                Button("Save config") { save() }
                Button("Unlock") { Task { await unlock(listMode: .root) } }
                    .disabled(busy)
                Button("Unlock and list") { Task { await unlock(listMode: .recursive) } }
                    .disabled(busy)
            } else {
                Button("List root") { Task { await unlock(listMode: .root) } }
                    .disabled(busy)
                Button("List recursive") { Task { await unlock(listMode: .recursive) } }
                    .disabled(busy)
            }
            Spacer()
            if bundledApp {
                Button("Mount in Finder") { Task { await mount() } }
                    .disabled(busy || jti == nil || !isUnlocked)
                Button("Unmount") { Task { await unmount() } }
                    .disabled(busy || jti == nil)
            }
        }
    }

    private var listingView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if listingLines.isEmpty {
                    Text("No listing yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(listingLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private enum ListMode {
        case none
        case root
        case recursive
    }

    // MARK: - Persistence

    private func load() {
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
        if settings.localVaultPath.isEmpty {
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

    private func chooseLocalVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Cryptomator vault directory (contains vault.cryptomator)."
        if panel.runModal() == .OK, let url = panel.url {
            settings.localVaultPath = url.path
        }
    }

    private func save(persistSecrets: Bool = true) {
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
            detail = "Save failed: \(error.localizedDescription)"
        }
    }

    private func resignFields() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func lock() {
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

    // MARK: - Vault

    @MainActor
    private func unlock(listMode: ListMode) async {
        busy = true
        defer { busy = false }
        status = .working

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
                status = .locked
                detail = "Endpoint, bucket, and access key are required (or choose a local vault)."
                return
            }
            guard !snapshotSecret.isEmpty else {
                status = .locked
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

            // Persist while we still have secrets in local vars, then drop focus
            // before swapping the SecureField form out of the hierarchy.
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
            status = .locked
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

    // MARK: - File Provider

    private func domain() -> NSFileProviderDomain? {
        guard let jti else { return nil }
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(AppIdentifiers.domainIdentifier(jti: jti)),
            displayName: "CryptoMako"
        )
    }

    private func mount() async {
        guard let domain = domain() else { return }
        busy = true
        defer { busy = false }
        do {
            try await NSFileProviderManager.add(domain)
            detail = "Mounted. Look under Locations in Finder, or ~/Library/CloudStorage."
        } catch {
            detail = "Mount failed: \(error.localizedDescription)"
        }
    }

    private func unmount() async {
        guard let domain = domain() else { return }
        busy = true
        defer { busy = false }
        do {
            try await NSFileProviderManager.remove(domain)
            detail = "Unmounted."
        } catch {
            detail = "Unmount failed: \(error.localizedDescription)"
        }
    }
}
