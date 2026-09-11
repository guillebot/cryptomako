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
    @State private var listing = ""
    @State private var jti: String?
    @State private var busy = false

    private var bundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CryptoMako").font(.title)
                Spacer()
                Text(status.rawValue)
                    .font(.headline)
                    .foregroundStyle(status.color)
            }
            Text("A Cryptomator format-8 vault, decrypted in-process.")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button("Save config") { save() }
            Button("Unlock") { Task { await unlock(list: false) } }
                .disabled(busy)
            Button("Unlock and list") { Task { await unlock(list: true) } }
                .disabled(busy)
            Spacer()
            if bundledApp {
                Button("Mount in Finder") { Task { await mount() } }
                    .disabled(busy || jti == nil)
                Button("Unmount") { Task { await unmount() } }
                    .disabled(busy || jti == nil)
            }
        }
    }

    private var listingView: some View {
        ScrollView {
            Text(listing.isEmpty ? "No listing yet." : listing)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

    private func save() {
        do {
            try settings.save()
            if !secretKey.isEmpty {
                try CredentialStore.saveSharedOrLocal(secretKey, account: AppIdentifiers.secretKeyAccount)
            }
            if !password.isEmpty {
                try CredentialStore.saveSharedOrLocal(password, account: AppIdentifiers.passwordAccount)
            }
            detail = "Saved. Settings are plaintext JSON; secrets are in the Keychain."
        } catch {
            detail = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Vault

    private func unlock(list: Bool) async {
        busy = true
        defer { busy = false }
        status = .working
        listing = ""

        guard !password.isEmpty else {
            status = .locked
            detail = "Vault password is required."
            return
        }

        let store: any ObjectStore
        let location: VaultLocation
        if settings.isLocal {
            store = DirectoryObjectStore(root: URL(fileURLWithPath: settings.localVaultPath))
            location = VaultLocation.local(prefix: "")
        } else {
            guard settings.isComplete, let endpoint = URL(string: settings.endpoint) else {
                status = .locked
                detail = "Endpoint, bucket, and access key are required (or choose a local vault)."
                return
            }
            guard !secretKey.isEmpty else {
                status = .locked
                detail = "Secret key is required for S3."
                return
            }
            store = S3ObjectStore(
                settings: S3Settings(
                    endpoint: endpoint,
                    region: settings.region,
                    bucket: settings.bucket,
                    accessKey: settings.accessKey,
                    secretKey: secretKey,
                    pathStyle: true
                )
            )
            location = VaultLocation(
                endpoint: endpoint,
                region: settings.region,
                bucket: settings.bucket,
                prefix: settings.prefix,
                accessKey: settings.accessKey
            )
        }

        do {
            let session = try await VaultSession.unlock(
                location: location,
                passphrase: password,
                store: store
            )
            status = .unlocked
            jti = session.config.jti
            var lines = [
                "format=\(session.config.format)",
                "combo=\(session.config.cipherCombo)",
                "root=\(session.rootCipherPrefix)",
                "jti=\(session.config.jti ?? "none")",
            ]
            if list {
                lines.append("")
                for (path, node) in try await session.listRecursive(at: "/") {
                    lines.append(path + (node.kind == .directory ? "/" : ""))
                }
            }
            listing = lines.joined(separator: "\n")
            detail = settings.isLocal
                ? "Unlock succeeded (local vault)."
                : "Unlock succeeded."
            save()
        } catch {
            status = .locked
            jti = nil
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
