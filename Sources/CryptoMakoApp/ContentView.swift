import AppKit
import CryptoMakoShared
import SwiftUI

/// Window shell. Deliberately does **not** observe `VaultAppModel`: on macOS 26 every
/// re-evaluation of a TabView's `tabItem`s (bridged to toolbar items) retained another
/// copy of the tab Labels, tag projections and Observation tracking state. With the
/// model publishing ~1×/s during Sync this grew to ~160k copies (~1.4 GB) and made each
/// layout pass progressively slower (main thread pinned at 100%). Tabs now rebuild only
/// when the selected tab or window visibility changes; tab contents observe the model.
struct ContentView: View {
    let model: VaultAppModel
    @ObservedObject private var tabs: MainTabSelection
    /// Close hides the window (orderOut) instead of destroying it. While it is hidden,
    /// minimized, or fully covered, the whole tree is swapped for an empty placeholder
    /// so Sync progress / transfer polling drive no SwiftUI work at all.
    @ObservedObject private var visibility = MainWindowVisibility.shared

    init(model: VaultAppModel) {
        self.model = model
        _tabs = ObservedObject(wrappedValue: model.tabSelection)
    }

    var body: some View {
        Group {
            if visibility.isVisible {
                TabView(selection: $tabs.selection) {
                    VaultTabView()
                        .tabItem { Label("Vault", systemImage: "lock.rectangle.stack") }
                        .tag(VaultAppModel.MainTab.vault)
                    BackupView(syncEngine: model.backupSync)
                        .tabItem { Label("Backup", systemImage: "externaldrive.badge.timemachine") }
                        .tag(VaultAppModel.MainTab.backup)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(VaultAppModel.MainTab.settings)
                }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(MainWindowAccessor())
        .modifier(AppTextSizeModifier(model: model))
        .environmentObject(model)
        .onAppear {
            // AppDelegate already called load() at launch. Only reconcile Finder lamp here.
            Task { await model.refreshMountState() }
        }
    }
}

/// Applies the window text size; observes the model itself so the shell above does not.
private struct AppTextSizeModifier: ViewModifier {
    @ObservedObject var model: VaultAppModel

    func body(content: Content) -> some View {
        content
            .environment(\.textPointAdjustment, model.textSize.pointAdjustment)
            .font(.system(size: CGFloat(13 + model.textSize.pointAdjustment)))
    }
}

struct VaultTabView: View {
    @State private var deleteRootName = "backupsfotosfamilia"
    @State private var confirmDeleteRoot = false
    @State private var deleteRootConfirmTyped = ""
    @State private var showTransferFailures = false
    @EnvironmentObject private var model: VaultAppModel

    var body: some View {
        vaultTab
    }

    private var vaultTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Keep chrome visible when the window is short; listing shrinks away first.
            VStack(alignment: .leading, spacing: 12) {
                header
                if !model.connectivityBanner.isEmpty {
                    connectivityBanner
                }
                transferStrip
                if model.isUnlocked {
                    sessionBanner
                } else {
                    credentialsForm
                }
                controls
                Text(model.detail)
                    .appFont(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .fixedSize(horizontal: false, vertical: true)

            listingView
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .layoutPriority(0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandIcon.swiftUIImage
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Text("CryptoMako").appFont(.title)
                    Spacer()
                    Text(model.status.rawValue)
                        .appFont(.headline)
                        .foregroundStyle(model.status.color)
                    if model.isUnlocked {
                        Button("Lock") { model.lock() }
                            .disabled(model.busy)
                    } else {
                        Button("Unlock") { Task { await model.unlock(listMode: .root) } }
                            .disabled(model.busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if model.isUnlocked {
                    Text("Signed in as \(model.sessionUser)")
                        .appFont(.subheadline, weight: .medium)
                } else {
                    Text("A Cryptomator format-8 vault, decrypted in-process.")
                        .foregroundStyle(.secondary)
                }
                pipelineStatus
            }
        }
    }

    private var pipelineStatus: some View {
        HStack(spacing: 16) {
            stageLamp(
                symbol: model.storageLampSymbol,
                title: model.storageLampLabel,
                subtitle: model.storageConnectivitySubtitle,
                lamp: model.storageLamp
            )
            stageLamp(
                symbol: "lock.open.fill",
                title: "Vault",
                subtitle: model.vaultLamp == .on ? "Unlocked" : (model.vaultLamp == .pending ? "Unlocking…" : "Locked"),
                lamp: model.vaultLamp
            )
            stageLamp(
                symbol: "macwindow",
                title: "Finder",
                subtitle: model.finderLamp == .on ? "Mounted" : "Not mounted",
                lamp: model.finderLamp
            )
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func stageLamp(symbol: String, title: String, subtitle: String, lamp: VaultAppModel.StageLamp) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(lamp.color.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(lamp.color)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .appFont(.caption, weight: .semibold)
                Text(subtitle)
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(title): \(subtitle)")
    }


    private var connectivityBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.red)
            Text(model.connectivityBanner)
                .appFont(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("S3 connectivity warning")
    }

    private var transferStrip: some View {
        let x = model.transfer
        return HStack(spacing: 14) {
            Label(
                x.inFlight > 0 ? "Uploading \(x.inFlight)" : "Remote idle",
                systemImage: x.inFlight > 0 ? "arrow.up.circle.fill" : "checkmark.circle"
            )
            .foregroundStyle(x.inFlight > 0 ? Color.orange : Color.secondary)
            Text("\(x.completedPuts) files · \(TransferSnapshot.formatBytes(x.bytesUploaded))")
                .foregroundStyle(.secondary)
            let liveRate = x.liveUploadBytesPerSecond()
            if liveRate > 0 {
                Text(TransferSnapshot.formatRate(liveRate))
                    .foregroundStyle(.secondary)
            }
            if let name = x.currentName, x.inFlight > 0 {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if x.failedPuts > 0 {
                let currentFailures = x.currentRunUnresolvedFailures.count
                let unresolvedFailures = x.unresolvedFailures.count
                Button {
                    showTransferFailures = true
                } label: {
                    Text(
                        currentFailures > 0
                            ? "\(currentFailures) need retry"
                            : (unresolvedFailures > 0
                                ? "\(unresolvedFailures) unresolved"
                                : "\(x.failedPuts) historical failures")
                    )
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Show failed transfer details")
            }
        }
        .appFont(.caption)
        .help(x.tooltip)
        .sheet(isPresented: $showTransferFailures) {
            TransferFailureSheet()
                .environmentObject(model)
        }
    }

    private var sessionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .appFont(.title)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.sessionUser)
                    .appFont(.headline)
                Text(model.sessionLocation)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Toggle(
                "Auto reconnect",
                isOn: Binding(
                    get: { model.settings.autoReconnect },
                    set: { model.settings.autoReconnect = $0; model.onAutoReconnectChanged() }
                )
            )
            .toggleStyle(.checkbox)
            .help("Reconnect when the S3 endpoint becomes reachable again.")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var credentialsForm: some View {
        Form {
            Picker("Storage", selection: $model.settings.storageMode) {
                Text("Local").tag(VaultSettings.StorageMode.local)
                Text("S3").tag(VaultSettings.StorageMode.s3)
            }
            .pickerStyle(.segmented)

            if model.settings.storageMode == .local {
                TextField("Local vault directory", text: $model.settings.localVaultPath)
                HStack {
                    Button("Choose…") { model.chooseLocalVault() }
                    Text("Directory that contains vault.cryptomator")
                        .foregroundStyle(.secondary)
                        .appFont(.caption)
                }
            } else {
                TextField("Endpoint", text: $model.settings.endpoint)
                TextField("Region", text: $model.settings.region)
                TextField("Bucket", text: $model.settings.bucket)
                TextField("Vault prefix (folder with vault.cryptomator)", text: $model.settings.prefix)
                Text("Object key the app will fetch: \(model.settings.vaultObjectKeyPreview)")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Leave prefix empty only if vault.cryptomator is at the bucket root. Non-empty values get a trailing slash on save.")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Access key", text: $model.settings.accessKey)
                SecureField("Secret key", text: $model.secretKey)
            }

            SecureField("Vault password", text: $model.password)

            Toggle(
                "Automatic connect / reconnect",
                isOn: Binding(
                    get: { model.settings.autoReconnect },
                    set: { model.settings.autoReconnect = $0; model.onAutoReconnectChanged() }
                )
            )
            .help("Unlock on launch and reconnect when the S3 endpoint becomes reachable again (VPN/internet).")
        }
    }

    private var controls: some View {
        HStack {
            if !model.isUnlocked {
                Button("Save config") { model.save() }
                Button("Unlock and list") { Task { await model.unlock(listMode: .recursive) } }
                    .disabled(model.busy)
            } else {
                Button("List root") { Task { await model.refreshListing(listMode: .root) } }
                    .disabled(model.busy)
                Button("List recursive") { Task { await model.refreshListing(listMode: .recursive) } }
                    .disabled(model.busy)
            }
            Spacer()
            if model.bundledApp {
                Text(model.isMounted ? "Finder: Mounted" : (model.isUnlocked ? "Finder: Mounting…" : "Finder: Off"))
                    .appFont(.caption)
                    .foregroundStyle(model.isMounted ? Color.green : Color.secondary)
                Menu("Finder") {
                    Button("Mount") { Task { await model.mount() } }
                        .disabled(model.busy || model.isUnmounting || !model.isUnlocked || model.isMounted)
                    Button(model.isUnmounting ? "Unmounting…" : "Unmount") { Task { await model.unmount() } }
                        .disabled(model.isUnmounting)
                    Button("Refresh") { Task { await model.refreshFinderMount() } }
                        .disabled(model.busy || model.isUnmounting || !model.isUnlocked)
                }
                .help("Unlocked vaults mount in Finder automatically. Use this menu to unmount, remount, or refresh.")
            }
        }
    }

    private var listingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Vault listing (S3 / local ciphertext)")
                    .appFont(.caption, weight: .semibold)
                Spacer()
                if !model.listingLines.isEmpty {
                    Text("\(model.listingEntryCount) entries")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(model.listingText)
                    .appFont(.body, design: .monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(4)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            HStack {
                TextField("Root item to delete", text: $deleteRootName)
                    .textFieldStyle(.roundedBorder)
                Button("Delete from vault…", role: .destructive) {
                    deleteRootConfirmTyped = ""
                    confirmDeleteRoot = true
                }
                .disabled(model.busy || !model.isUnlocked || deleteRootName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .alert(
                    "Permanently delete from vault?",
                    isPresented: $confirmDeleteRoot
                ) {
                    TextField("Type \(deleteRootName) to confirm", text: $deleteRootConfirmTyped)
                    Button("Delete permanently", role: .destructive) {
                        let target = deleteRootName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard deleteRootConfirmTyped == target, !target.isEmpty else { return }
                        Task { await model.deleteRootItem(named: target) }
                        deleteRootConfirmTyped = ""
                    }
                    .disabled(
                        deleteRootConfirmTyped
                            != deleteRootName.trimmingCharacters(in: .whitespacesAndNewlines)
                            || deleteRootName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    Button("Cancel", role: .cancel) {
                        deleteRootConfirmTyped = ""
                    }
                } message: {
                    Text(
                        "This cannot be undone. Type the exact root name \"\(deleteRootName)\" to enable Delete."
                    )
                }
            }
            .help("Use this for huge folders like backupsfotosfamilia — Finder Trash hits Error -36 while remote deletes run.")

            Text("Finder mount is for viewing and small transfers. Use the Backup tab for bulk folder sync.")
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

private struct TransferFailureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: VaultAppModel

    private var failures: [TransferFailure] {
        model.transfer.failureHistory.sorted { $0.timestamp > $1.timestamp }
    }

    private var retryableSourceCount: Int {
        Set(
            model.transfer.currentRunUnresolvedFailures
                .filter(\.retryable)
                .compactMap(\.sourceID)
        ).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transfer failures")
                        .appFont(.title2, weight: .semibold)
                    if let started = model.transfer.latestRunStartedAt {
                        Text("Latest run started \(started.formatted(date: .abbreviated, time: .standard))")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if failures.isEmpty {
                if model.transfer.failedPuts > 0 {
                    ContentUnavailableView(
                        "Legacy failure count",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "\(model.transfer.failedPuts) failures predate detailed history. Clear history to remove the old count."
                        )
                    )
                } else {
                    ContentUnavailableView(
                        "No transfer failures",
                        systemImage: "checkmark.circle",
                        description: Text("Detailed failures from future Backup runs will appear here.")
                    )
                }
            } else {
                HStack(spacing: 14) {
                    Text("\(model.transfer.currentRunUnresolvedFailures.count) unresolved in latest run")
                    Text("\(model.transfer.unresolvedFailures.count) unresolved in history")
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)

                List(failures) { failure in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(failure.path)
                                .appFont(.body, design: .monospaced)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Text(failure.status == .resolved ? "Resolved" : (failure.retryable ? "Retryable" : "Needs attention"))
                                .appFont(.caption, weight: .semibold)
                                .foregroundStyle(
                                    failure.status == .resolved
                                        ? Color.green
                                        : (failure.retryable ? Color.orange : Color.red)
                                )
                        }
                        Text(
                            "\(failure.timestamp.formatted(date: .abbreviated, time: .standard)) · \(failure.category) · \(failure.operation) · \(failure.attempts) attempt\(failure.attempts == 1 ? "" : "s")"
                        )
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        Text(failure.message)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button("Retry failed") {
                    model.retryFailedTransfers()
                    dismiss()
                }
                .disabled(retryableSourceCount == 0 || model.backupSync.isRunning)
                .help("Rerun affected Backup sources; unchanged files are skipped")
                Spacer()
                Button("Clear history", role: .destructive) {
                    model.clearTransferFailureHistory()
                }
                .disabled(model.transfer.failedPuts == 0 && failures.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 420)
    }
}

// MARK: - Backup tab

private struct TransferModePicker: View {
    @Binding var mode: AppPreferences.BackupTransferMode
    let disabled: Bool

    var body: some View {
        Picker("Transfer mode", selection: $mode) {
            Text("Backup").tag(AppPreferences.BackupTransferMode.backup)
            Text("Sync").tag(AppPreferences.BackupTransferMode.sync)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(disabled)
        .help("Backup = put/update only. Sync = put/update plus delete vault-only files under this source’s Backups folder.")
    }
}

struct BackupView: View {
    @EnvironmentObject private var model: VaultAppModel
    @ObservedObject var syncEngine: BackupSyncEngine
    @State private var showAddSMB = false
    @State private var smbURLText = "smb://"
    @State private var smbUsername = ""
    @State private var smbPassword = ""
    @State private var smbBusy = false
    @State private var smbFormError = ""
    @State private var prefs = AppPreferences.load()
    @State private var prefsReady = false

    private var transferMode: AppPreferences.BackupTransferMode {
        prefs.backupTransferMode
    }

    private var runVerb: String {
        transferMode == .sync ? "Sync" : "Backup"
    }

    private var runAllLabel: String {
        transferMode == .sync ? "Sync all" : "Backup all"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backup")
                .appFont(.title2, weight: .semibold)
            Text("Pick local folders or add an explicit SMB share (smb://…). Transfer uses bounded parallel remote puts (many small files, one large at a time) so it does not fill CloudStorage like rclone-into-Finder did. SMB uses macOS mounts under /Volumes — remount-on-demand before a run; fail-closed if the share drops. Never deletes files on the source.")
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Transfer mode") {
                VStack(alignment: .leading, spacing: 8) {
                    // Own view: re-evaluating a segmented Picker inside BackupView on every
                    // Sync progress publish retained its tag projections (see ContentView).
                    TransferModePicker(mode: $prefs.backupTransferMode, disabled: syncEngine.isRunning)

                    if transferMode == .backup {
                        Text("Backup copies and updates into the vault. It never deletes the local source, and it does not remove vault files that are missing locally.")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Sync copies and updates, then deletes ciphertext in the vault under each source’s Backups/<folder>/ that is missing from the local tree. It never deletes the local source. Prefer Backup unless you intentionally want vault orphans removed.")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            GroupBox("Sync volume (macFUSE — optional)") {
                Text("Not required for Backup / Sync. Use the direct put path when FUSE is blocked by policy; data still lands in vault Backups/ and shows in the Finder CryptoMako mount after refresh.")
                    .appFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.fuseMount.statusSummary)
                        .appFont(.caption)
                        .textSelection(.enabled)
                    HStack {
                        Button(model.fuseMount.isMounted ? "Mounted" : "Mount sync volume") {
                            model.mountSyncVolume()
                        }
                        .disabled(!model.isUnlocked || model.fuseMount.isMounted)
                        Button("Unmount") { model.unmountSyncVolume() }
                            .disabled(!model.fuseMount.isMounted)
                    }
                }
                .padding(4)
            }

            syncStatus

            GroupBox("Source folders") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.backupSources.isEmpty {
                        Text("No folders yet.")
                            .foregroundStyle(.secondary)
                            .appFont(.callout)
                    } else {
                        ScrollView {
                        ForEach(model.backupSources) { source in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(source.vaultFolderName)
                                            .appFont(.body, weight: .medium)
                                        if let at = source.lastFullSyncAt {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .imageScale(.small)
                                                .accessibilityLabel("Fully synced")
                                                .help("Last full sync \(FullSyncAgoFormatting.string(from: at))")
                                        }
                                        if source.isSMB {
                                            Text("SMB")
                                                .appFont(.caption2, weight: .semibold)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.accentColor.opacity(0.15))
                                                .foregroundStyle(Color.accentColor)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(source.displayLocation)
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    if source.isSMB, source.path != source.displayLocation {
                                        Text(source.path)
                                            .appFont(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .textSelection(.enabled)
                                    }
                                    Text("→ Backups/\(source.vaultFolderName)/")
                                        .appFont(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 8)
                                if syncEngine.isRunning, syncEngine.currentSourceName == source.vaultFolderName {
                                    HStack(spacing: 6) {
                                        // Static glyph: a per-row indeterminate spinner kept the
                                        // whole Backup tree in a continuous redraw/layout pass.
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .imageScale(.small)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Syncing")
                                        Text(syncEngine.phaseLabel.isEmpty ? "Syncing…" : syncEngine.phaseLabel)
                                            .appFont(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(minWidth: 88, alignment: .trailing)
                                }
                                Button(runVerb) {
                                    model.startBackupSync(sourceID: source.id)
                                }
                                .disabled(!model.isUnlocked || syncEngine.isRunning)
                                .help(transferMode == .sync
                                      ? "Sync this folder into Backups/\(source.vaultFolderName)/ (puts + delete vault-only files under that folder)"
                                      : "Backup this folder into Backups/\(source.vaultFolderName)/ (put/update only; no vault deletes)")
                                Button(role: .destructive) {
                                    model.removeBackupSource(source.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .disabled(syncEngine.isRunning)
                            }
                            Divider()
                        }
                        }
                        // Grow with the window so several sources stay visible without scrolling.
                        // Add/Cancel/Backup-all stay outside this ScrollView (intrinsic height).
                        // ScrollView already takes the proposed height; an extra unbounded
                        // flexible frame here only added another nested sizing pass.
                        .frame(minHeight: 280)
                    }
                    HStack {
                        Button("Add folders…") { model.addBackupFolder() }
                            .disabled(syncEngine.isRunning)
                        Button("Add SMB share…") {
                            smbFormError = ""
                            smbURLText = "smb://"
                            smbUsername = ""
                            smbPassword = ""
                            showAddSMB = true
                        }
                        .disabled(syncEngine.isRunning)
                        .help("Mount smb://server/share via macOS and add it as a Backup source")
                        Spacer()
                        if syncEngine.isRunning {
                            Button("Cancel", role: .destructive) { model.cancelBackupSync() }
                                .help("Stop the in-progress transfer (vault data already uploaded is kept; source is never deleted)")
                        }
                        Button(runAllLabel) { model.startBackupSync() }
                            .disabled(!model.isUnlocked || model.backupSources.isEmpty || syncEngine.isRunning)
                            .help(transferMode == .sync
                                  ? "Sync every listed folder: put/update then delete vault-only files under each Backups/<folder>/"
                                  : "Backup every listed folder: put/update only (no vault deletes, no source deletes)")
                        Button("Sync via rclone+FUSE") { model.startRcloneBackupSync() }
                            .disabled(!model.isUnlocked || model.backupSources.isEmpty || syncEngine.isRunning || !RcloneDriver.isAvailable)
                            .keyboardShortcut(.defaultAction)
                            .help("rclone copy into /Volumes/CryptoMakoSync; FUSE flushes each file to MinIO")
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 340, maxHeight: .infinity)
            .layoutPriority(1)
            .sheet(isPresented: $showAddSMB) {
                addSMBSheet
            }

            if !model.rcloneLog.isEmpty {
                GroupBox("rclone output") {
                    ScrollView {
                        Text(model.rcloneLog)
                            .appFont(.caption2, design: .monospaced)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }

            GroupBox("Related settings") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bandwidth cap, put-worker concurrency, and path excludes live in Settings.")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Transfer mode…") { model.openSettings(section: .transferMode) }
                        Button("Bandwidth…") { model.openSettings(section: .bandwidth) }
                        Button("Sync workers…") { model.openSettings(section: .syncWorkers) }
                        Button("Excludes…") { model.openSettings(section: .excludes) }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Finder File Provider stays the viewer. Bulk transfer uses direct puts or rclone→\(FuseMountController.preferredMountURL.path). Source folders are never deleted.")
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            prefs = AppPreferences.load()
            prefsReady = true
        }
        .onChange(of: prefs.backupTransferMode) { _, _ in
            guard prefsReady else { return }
            do {
                try prefs.save()
            } catch {
                model.detail = "Could not save transfer mode: \(error.localizedDescription)"
            }
        }
        .onExitCommand(perform: syncEngine.isRunning ? { model.cancelBackupSync() } : nil)
    }

    @ViewBuilder
    private var addSMBSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add SMB share")
                .appFont(.title3, weight: .semibold)
            Text("CryptoMako uses macOS mounting under /Volumes (NetFS / system Connect to Server — no embedded SMB client). Password is stored in Keychain; remount-on-demand before Sync. macOS may prompt to connect or for Local Network access. After mount you can use the share root or pick a subfolder.")
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("smb://server/share/optional/path", text: $smbURLText)
                .textFieldStyle(.roundedBorder)
            TextField("Username (optional)", text: $smbUsername)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $smbPassword)
                .textFieldStyle(.roundedBorder)
            if !smbFormError.isEmpty {
                Text(smbFormError)
                    .appFont(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") {
                    smbPassword = ""
                    showAddSMB = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(smbBusy ? "Mounting…" : "Mount & add") {
                    smbBusy = true
                    smbFormError = ""
                    defer { smbBusy = false }
                    do {
                        let added = try model.addSMBShare(
                            urlString: smbURLText,
                            username: smbUsername,
                            password: smbPassword,
                            promptForSubfolder: true
                        )
                        smbPassword = ""
                        if added || model.detail.contains("already in the list") {
                            showAddSMB = false
                        } else {
                            smbFormError = model.detail
                        }
                    } catch {
                        smbFormError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(smbBusy || smbURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func backupProgressLabels(_ engine: BackupSyncEngine) -> some View {
        HStack {
            Text("\(engine.phaseLabel.isEmpty ? "Syncing…" : engine.phaseLabel) · \(engine.progressPercentLabel)")
                .appFont(.body, weight: .semibold)
            Spacer()
            if engine.walkFinished {
                Text("\(engine.filesUploaded)/\(max(engine.filesToUpload, engine.filesUploaded)) files · \(TransferSnapshot.formatBytes(engine.bytesUploaded))/\(TransferSnapshot.formatBytes(max(engine.bytesToUpload, engine.bytesUploaded)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Discovered \(engine.filesDiscovered.formatted()) · \(TransferSnapshot.formatBytes(engine.bytesDiscovered))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        let engine = syncEngine
        GroupBox("Last transfer") {
            VStack(alignment: .leading, spacing: 6) {
                switch engine.state {
                case .idle:
                    Text("Idle")
                        .foregroundStyle(.secondary)
                case .running:
                    Group {
                        if engine.hasDeterminateUploadProgress {
                            ProgressView(value: engine.progressFraction) {
                                backupProgressLabels(engine)
                            }
                        } else {
                            // Scan phase: static empty bar (no indeterminate animation).
                            ProgressView(value: 0.0) {
                                backupProgressLabels(engine)
                            }
                        }
                    }
                    // "Still to transfer" — exact once the scan finished, before the first put.
                    if !engine.remainingLabel.isEmpty {
                        Text(engine.remainingLabel)
                            .appFont(.body, weight: .medium)
                            .foregroundStyle(engine.walkFinished ? .primary : .secondary)
                    }
                    HStack(spacing: 12) {
                        Text("Discovered \(engine.filesDiscovered.formatted())")
                        Text("Skipped \(engine.filesSkipped.formatted()) (\(TransferSnapshot.formatBytes(engine.bytesSkipped)))")
                        Text("To upload \(engine.filesToUpload.formatted()) (\(TransferSnapshot.formatBytes(engine.bytesToUpload)))")
                        Text("Uploaded \(engine.filesUploaded.formatted()) (\(TransferSnapshot.formatBytes(engine.bytesUploaded)))")
                        if engine.filesDeleted > 0 || engine.phase == .pruning {
                            Text("Vault deleted \(engine.filesDeleted)")
                        }
                    }
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    if !engine.walkFinished {
                        Text("Scanning only — no uploads yet. Percent starts at 0% when the scan finishes.")
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if engine.uploadBytesPerSecond > 0 {
                        Text("Job bandwidth: \(TransferSnapshot.formatRate(engine.uploadBytesPerSecond))")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !engine.currentSourceName.isEmpty {
                        Text("Folder: \(engine.currentSourceName)")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !engine.currentPath.isEmpty {
                        Text(engine.currentPath)
                            .appFont(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .destructive) { model.cancelBackupSync() }
                        .help("Stop the in-progress transfer (vault uploads kept; source never deleted). Escape also cancels.")
                case .finished(let files, let bytes):
                    if engine.filesDeleted > 0 {
                        Text("Finished — \(files) files, \(TransferSnapshot.formatBytes(bytes)) processed; removed \(engine.filesDeleted) vault-only item(s). Source untouched.")
                            .foregroundStyle(.green)
                    } else {
                        Text("Finished — \(files) files, \(TransferSnapshot.formatBytes(bytes)) processed (skipped + uploaded). Source untouched.")
                            .foregroundStyle(.green)
                    }
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}


// MARK: - Relative “ago” for last full sync tick

private enum FullSyncAgoFormatting {
    static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func string(from date: Date, now: Date = Date()) -> String {
        formatter.localizedString(for: date, relativeTo: now)
    }
}

