import CryptoMakoShared
import SwiftUI

/// App Settings: network proxy, Sync bandwidth cap, and Backup Sync excludes.
struct SettingsView: View {
    @EnvironmentObject private var model: VaultAppModel

    @State private var prefs = AppPreferences.load()
    @State private var proxyPassword = ""
    @State private var excludes = BackupSyncExcludesStore.load()
    @State private var customDirectoryName = ""
    @State private var statusMessage = ""
    @State private var enabledDefaultDirs: Set<String> = []

    private let defaultDirCatalog = BackupSyncExcludes.defaultDirectoryNames.sorted()
    private let defaultFileCatalog = BackupSyncExcludes.defaultFileNames.sorted()
    private let defaultExtCatalog = BackupSyncExcludes.defaultFileExtensions.sorted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Text("Network, Sync bandwidth, and path excludes. Vault endpoint / bucket / password stay on the Vault tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                networkSection
                bandwidthSection
                excludesSection

                HStack {
                    Button("Save") { saveAll() }
                        .keyboardShortcut(.defaultAction)
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                Text("Proxy changes apply after Unlock / reconnect (URLSession pools are built at unlock). Bandwidth and excludes apply to the next Sync run.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reloadFromDisk)
    }

    // MARK: - Network / Proxy

    private var networkSection: some View {
        GroupBox("Network / Proxy") {
            Form {
                Picker("Proxy mode", selection: $prefs.proxyMode) {
                    Text("System").tag(AppPreferences.ProxyMode.system)
                    Text("Direct (no proxy)").tag(AppPreferences.ProxyMode.direct)
                    Text("Custom HTTP(S)").tag(AppPreferences.ProxyMode.custom)
                }
                .pickerStyle(.segmented)

                if prefs.proxyMode == .custom {
                    TextField("Host", text: $prefs.proxyHost)
                    TextField("Port", value: $prefs.proxyPort, format: .number)
                    TextField("Username (optional)", text: $prefs.proxyUsername)
                    SecureField("Password (optional, Keychain)", text: $proxyPassword)
                }

                Text(proxyHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var proxyHelp: String {
        switch prefs.proxyMode {
        case .system:
            return "Uses the macOS system proxy / PAC. Default."
        case .direct:
            return "Bypasses HTTP(S) system proxies for CryptoMako S3 sessions (useful behind Zscaler-style middleboxes when you want a direct path)."
        case .custom:
            return "Routes S3 URLSessions through the given HTTP(S) proxy. Password is stored in the Keychain; host/port/user in app-group JSON."
        }
    }

    // MARK: - Bandwidth

    private var bandwidthSection: some View {
        GroupBox("Backup Sync bandwidth") {
            Form {
                Toggle("Limit Sync upload bandwidth", isOn: $prefs.limitSyncUploadBandwidth)
                if prefs.limitSyncUploadBandwidth {
                    HStack {
                        Text("Cap")
                        TextField("Mbps", value: $prefs.syncUploadCapMbps, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 72)
                        Text("Mbps")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $prefs.syncUploadCapMbps, in: 1...1000, step: 5)
                            .labelsHidden()
                    }
                }
                Text("Applies only to Backup Sync puts (token-bucket pacing). Finder File Provider transfers are unchanged. Takes effect on the next Sync run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    // MARK: - Excludes

    private var excludesSection: some View {
        GroupBox("Backup Sync excludes") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Directory names (skip entire trees)")
                    .font(.caption.weight(.semibold))
                FlowChips(
                    items: defaultDirCatalog,
                    isOn: { enabledDefaultDirs.contains($0) },
                    toggle: { name in
                        if enabledDefaultDirs.contains(name) {
                            enabledDefaultDirs.remove(name)
                            excludes.directoryNames.remove(name)
                        } else {
                            enabledDefaultDirs.insert(name)
                            excludes.directoryNames.insert(name)
                        }
                    }
                )

                let customDirs = excludes.directoryNames.subtracting(BackupSyncExcludes.defaultDirectoryNames).sorted()
                if !customDirs.isEmpty {
                    Text("Custom directories")
                        .font(.caption.weight(.semibold))
                    ForEach(customDirs, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button(role: .destructive) {
                                excludes.directoryNames.remove(name)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    TextField("Add directory name", text: $customDirectoryName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addCustomDirectory() }
                        .disabled(customDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider()

                Text("File names")
                    .font(.caption.weight(.semibold))
                FlowChips(
                    items: defaultFileCatalog,
                    isOn: { excludes.fileNames.contains($0) },
                    toggle: { name in
                        if excludes.fileNames.contains(name) {
                            excludes.fileNames.remove(name)
                        } else {
                            excludes.fileNames.insert(name)
                        }
                    }
                )

                Text("Extensions (no dot)")
                    .font(.caption.weight(.semibold))
                FlowChips(
                    items: defaultExtCatalog,
                    isOn: { excludes.fileExtensions.contains($0) },
                    toggle: { ext in
                        if excludes.fileExtensions.contains(ext) {
                            excludes.fileExtensions.remove(ext)
                        } else {
                            excludes.fileExtensions.insert(ext)
                        }
                    }
                )

                Text("Applies to the next Sync run (scan + upload). Already-queued Sync keeps its snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    // MARK: - Actions

    private func reloadFromDisk() {
        prefs = AppPreferences.load()
        excludes = BackupSyncExcludesStore.load()
        enabledDefaultDirs = Set(excludes.directoryNames).intersection(BackupSyncExcludes.defaultDirectoryNames)
        proxyPassword = (try? CredentialStore.readSharedOrLocal(
            account: AppIdentifiers.proxyPasswordAccount
        )) ?? ""
        statusMessage = ""
    }

    private func addCustomDirectory() {
        let name = customDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        excludes.directoryNames.insert(name)
        if BackupSyncExcludes.defaultDirectoryNames.contains(name) {
            enabledDefaultDirs.insert(name)
        }
        customDirectoryName = ""
    }

    private func saveAll() {
        // Rebuild directoryNames from toggles + custom
        var dirs = excludes.directoryNames.subtracting(BackupSyncExcludes.defaultDirectoryNames)
        dirs.formUnion(enabledDefaultDirs)
        excludes.directoryNames = dirs

        if prefs.syncUploadCapMbps < 1 {
            prefs.syncUploadCapMbps = 1
        }

        do {
            try prefs.save()
            BackupSyncExcludesStore(excludes: excludes).save()
            if prefs.proxyMode == .custom, !proxyPassword.isEmpty {
                try CredentialStore.saveSharedOrLocal(
                    proxyPassword,
                    account: AppIdentifiers.proxyPasswordAccount
                )
            }
            if prefs.proxyMode != .custom {
                CredentialStore.delete(account: AppIdentifiers.proxyPasswordAccount, useAccessGroup: true)
                CredentialStore.delete(account: AppIdentifiers.proxyPasswordAccount, useAccessGroup: false)
            }
            statusMessage = "Saved. Reconnect/Unlock for proxy; next Sync for bandwidth & excludes."
            model.detail = statusMessage
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// Simple wrapping chip row for toggleable exclude names.
private struct FlowChips: View {
    let items: [String]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        // LazyVGrid keeps layout simple without a FlowLayout dependency.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Toggle(item, isOn: Binding(
                    get: { isOn(item) },
                    set: { _ in toggle(item) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
    }
}
