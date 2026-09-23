import AppKit
import CryptoMakoShared
import SwiftUI

/// App Settings: About/updates, network proxy, Sync bandwidth, put-worker tuning, and Backup Sync excludes.
/// Changes auto-persist (no explicit Save). Proxy applies after Unlock/reconnect; Sync knobs on next Sync run.
struct SettingsView: View {
    @EnvironmentObject private var model: VaultAppModel

    @State private var prefs = AppPreferences.load()
    @State private var proxyPassword = ""
    @State private var excludes = BackupSyncExcludesStore.load()
    @State private var customDirectoryName = ""
    @State private var statusMessage = ""
    @State private var enabledDefaultDirs: Set<String> = []
    @State private var ready = false
    @State private var checkingUpdates = false

    private let defaultDirCatalog = BackupSyncExcludes.defaultDirectoryNames.sorted()
    private let defaultFileCatalog = BackupSyncExcludes.defaultFileNames.sorted()
    private let defaultExtCatalog = BackupSyncExcludes.defaultFileExtensions.sorted()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("Network, Sync workers & bandwidth, path excludes, and About. Vault endpoint / bucket / password stay on the Vault tab. Changes save automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    aboutSection
                        .id(VaultAppModel.SettingsSection.about)
                    networkSection
                        .id(VaultAppModel.SettingsSection.network)
                    bandwidthSection
                        .id(VaultAppModel.SettingsSection.bandwidth)
                    syncWorkersSection
                        .id(VaultAppModel.SettingsSection.syncWorkers)
                    excludesSection
                        .id(VaultAppModel.SettingsSection.excludes)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Text("Proxy changes apply after Unlock / reconnect (URLSession pools are built at unlock). Bandwidth, workers, and excludes apply to the next Sync run.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                reloadFromDisk()
                ready = true
                scrollToFocus(using: proxy)
            }
            .onChange(of: model.settingsFocus) { _, _ in
                scrollToFocus(using: proxy)
            }
            .onChange(of: prefs) { _, _ in
                guard ready else { return }
                persistPrefs()
            }
            .onChange(of: excludes) { _, _ in
                guard ready else { return }
                persistExcludes()
            }
            .onChange(of: enabledDefaultDirs) { _, _ in
                guard ready else { return }
                persistExcludes()
            }
            .onChange(of: proxyPassword) { _, _ in
                guard ready else { return }
                persistProxyPassword()
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    BrandIcon.swiftUIImage
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CryptoMako")
                            .font(.headline)
                        Text("Version \(AppVersion.displayString)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("AGPLv3 · github.com/guillebot/cryptomako")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { @MainActor in
                            checkingUpdates = true
                            await UpdateChecker.checkAndPresent()
                            checkingUpdates = false
                        }
                    } label: {
                        if checkingUpdates {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        } else {
                            Text("Check for Updates…")
                        }
                    }
                    .disabled(checkingUpdates)

                    Button("About panel…") {
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.showAbout()
                        }
                    }
                }

                Text("Update checks use the public GitHub Releases API. Private repos or no published release show a clear message — never crashes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: - Sync workers

    private var syncWorkersSection: some View {
        GroupBox("Backup Sync workers") {
            Form {
                workerRow(
                    title: "Small files",
                    help: "Concurrent puts under 256 KB (many tiny files).",
                    value: $prefs.syncSmallPutConcurrency,
                    range: 1...256,
                    step: 8
                )
                workerRow(
                    title: "Medium files",
                    help: "Concurrent puts 256 KB .. 32 MB.",
                    value: $prefs.syncMediumPutConcurrency,
                    range: 1...128,
                    step: 4
                )
                workerRow(
                    title: "Large files",
                    help: "Concurrent puts over 32 MB (memory-bound).",
                    value: $prefs.syncLargePutConcurrency,
                    range: 1...16,
                    step: 1
                )
                Button("Reset to defaults (96 / 32 / 4)") {
                    prefs.syncSmallPutConcurrency = 96
                    prefs.syncMediumPutConcurrency = 32
                    prefs.syncLargePutConcurrency = 4
                }
                .font(.caption)
                Text("Surfaces the BackupSyncEngine put pools. Higher small/medium counts fill a home uplink; keep large low to avoid multi-GB streams. Applies on the next Sync run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private func workerRow(
        title: String,
        help: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: value, format: .number)
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    // MARK: - Persistence

    private func scrollToFocus(using proxy: ScrollViewProxy) {
        guard let focus = model.settingsFocus else { return }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(focus, anchor: .top)
            }
            // Clear so re-opening the same section still scrolls next time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if model.settingsFocus == focus {
                    model.settingsFocus = nil
                }
            }
        }
    }

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
        // onChange(excludes) persists
    }

    private func persistPrefs() {
        prefs.clampSyncWorkers()
        do {
            try prefs.save()
            if prefs.proxyMode != .custom {
                CredentialStore.delete(account: AppIdentifiers.proxyPasswordAccount, useAccessGroup: true)
                CredentialStore.delete(account: AppIdentifiers.proxyPasswordAccount, useAccessGroup: false)
            }
            statusMessage = "Saved. Reconnect/Unlock for proxy; next Sync for bandwidth & workers."
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func persistExcludes() {
        var snapshot = excludes
        var dirs = snapshot.directoryNames.subtracting(BackupSyncExcludes.defaultDirectoryNames)
        dirs.formUnion(enabledDefaultDirs)
        snapshot.directoryNames = dirs
        BackupSyncExcludesStore(excludes: snapshot).save()
        statusMessage = "Saved. Excludes apply on the next Sync run."
    }

    private func persistProxyPassword() {
        do {
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
            statusMessage = "Saved. Reconnect/Unlock for proxy."
        } catch {
            statusMessage = "Proxy password save failed: \(error.localizedDescription)"
        }
    }
}

/// Simple wrapping chip row for toggleable exclude names.
private struct FlowChips: View {
    let items: [String]
    let isOn: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
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
