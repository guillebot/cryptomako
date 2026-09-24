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
    /// TCP reachability of settings.endpoint (S3). nil = not probed yet / local mode.
    @Published var endpointReachable: Bool? = nil
    @Published var connectivityBanner: String = ""
    /// User wants an unlocked session (Unlock or auto-reconnect on launch); cleared by Lock.
    private var userWantsUnlocked = false
    private var connectivityTask: Task<Void, Never>?
    private var lastReachable: Bool?
    /// `load()` runs from AppDelegate and ContentView.onAppear — only bootstrap once.
    private var didLoadOnce = false
    /// Prevent overlapping unlock sessions (auto-reconnect + Unlock button).
    private var unlockInFlight = false
    @Published var detail = ""
    @Published var listingLines: [String] = []
    @Published var jti: String?
    @Published var busy = false
    /// True while Unmount is draining transfers / removing domains (does not block Mount forever via busy).
    @Published var isUnmounting = false
    @Published var sessionUser = ""
    @Published var sessionLocation = ""
    /// True when the CryptoMako File Provider domain is registered (Finder mount).
    @Published var isMounted = false
    /// Remote transfer stats from the File Provider (App Group).
    @Published var transfer = TransferSnapshot.empty
    @Published var backupSources: [BackupSource] = []
    let backupSync = BackupSyncEngine()
    let fuseMount = FuseMountController.shared
    @Published var rcloneLog: String = ""

    /// Main window tabs (Vault / Backup / Settings). Driven by TabView + ⌘,.
    enum MainTab: Hashable {
        case vault
        case backup
        case settings
    }

    /// Optional Settings subsection to scroll/highlight when opening from Backup links or menu.
    enum SettingsSection: String, Hashable {
        case about
        case network
        case transferMode
        case bandwidth
        case syncWorkers
        case excludes
    }

    @Published var selectedTab: MainTab = .vault
    @Published var settingsFocus: SettingsSection? = nil

    func openSettings(section: SettingsSection? = nil) {
        settingsFocus = section
        selectedTab = .settings
    }

    /// Kept while unlocked so List root / List recursive can refresh without a full re-unlock.
    private var activeSession: VaultSession?
    private var activeStore: (any ObjectStore)?

    var bundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var isUnlocked: Bool {
        status == .unlocked
    }

    /// Monospace blob for the listing pane (avoids SwiftUI ForEach refresh quirks).
    var listingText: String {
        if listingLines.isEmpty {
            return "No listing yet. Unlock or press List root / List recursive."
        }
        return listingLines.joined(separator: "\n")
    }

    /// Count of real vault entries (skips metadata header lines).
    var listingEntryCount: Int {
        listingLines.filter { line in
            !line.isEmpty
                && !line.hasPrefix("format=")
                && !line.hasPrefix("combo=")
                && !line.hasPrefix("root=")
                && !line.hasPrefix("jti=")
                && !line.hasPrefix("…")
        }.count
    }

    /// Pipeline lamp for the main window (menu bar keeps using `status` alone).
    enum StageLamp: Equatable {
        case off, pending, on, failed

        var color: Color {
            switch self {
            case .off: return Color.secondary.opacity(0.45)
            case .pending: return .orange
            case .on: return .green
            case .failed: return .red
            }
        }
    }

    /// Storage backend reachable for this session (S3 or local directory).
    var storageLamp: StageLamp {
        if !settings.isLocal, endpointReachable == false { return .failed }
        if status == .connecting { return .pending }
        if status == .error && !isUnlocked { return .failed }
        if !settings.isLocal, endpointReachable == true, (activeStore != nil || isUnlocked) { return .on }
        if activeStore != nil || isUnlocked { return .on }
        if !settings.isLocal, endpointReachable == true { return .on }
        return .off
    }

    var storageLampLabel: String {
        settings.isLocal ? "Local" : "S3"
    }

    var storageConnectivitySubtitle: String {
        if settings.isLocal {
            return storageLamp == .on ? "Connected" : (storageLamp == .pending ? "Connecting…" : "Not connected")
        }
        if endpointReachable == false {
            return "No connectivity"
        }
        if storageLamp == .on { return "Connected" }
        if storageLamp == .pending { return "Connecting…" }
        if storageLamp == .failed { return "Unreachable" }
        return "Not connected"
    }

    var storageLampSymbol: String {
        settings.isLocal ? "folder.fill" : "externaldrive.connected.to.line.below"
    }

    var vaultLamp: StageLamp {
        if status == .connecting { return .pending }
        if status == .error && !isUnlocked { return .failed }
        if isUnlocked { return .on }
        return .off
    }

    var finderLamp: StageLamp {
        if isMounted { return .on }
        if status == .error, detail.lowercased().contains("mount") { return .failed }
        return .off
    }

    func load() {
        settings = VaultSettings.load() ?? VaultSettings()
        secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        backupSources = BackupSourcesStore.load().sources
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
            _ = ensureFileProviderExtensionEnabled()
            detail = "Unlock — Finder mounts automatically."
        } else {
            detail = "Running from swift run. Use a local vault or S3; Finder mount needs the signed .app."
        }
        if didLoadOnce {
            // Window re-appeared: refresh mount lamp only — do not re-run auto-unlock.
            Task { await refreshMountState() }
            refreshTransfers()
            return
        }
        didLoadOnce = true
        Task { await refreshMountState() }
        refreshTransfers()
        startConnectivityMonitor()
        if settings.autoReconnect {
            userWantsUnlocked = true
            Task { await self.attemptAutoUnlock(reason: "launch") }
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
        userWantsUnlocked = false
        resignFields()
        // High: stop Backup Sync / rclone and drop cleartext FUSE before clearing
        // session so masterkey cannot survive UI Lock via the sync volume.
        // Idempotent when already locked / no mount / no sync. Keychain untouched.
        cancelBackupSync()
        RcloneDriver.cancel()
        fuseMount.unmount()
        let storeToClose = activeStore
        activeStore = nil
        activeSession = nil
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
        detail = "Locked. Sync cancelled; cleartext volume and Finder domain unmounting."
        // Disconnect must kill the File Provider mount path — otherwise leftover CloudStorage fills.
        Task {
            await self.unmountAllDomains(cleanupLeftoverFolder: true)
            if let storeToClose, let s3 = storeToClose as? S3ObjectStore {
                try? await s3.shutdown()
            }
        }
    }

    /// Refresh the listing using the already-unlocked session (no passphrase prompt).
    func refreshListing(listMode: ListMode) async {
        guard listMode == .root || listMode == .recursive else { return }
        guard let session = activeSession, status == .unlocked else {
            await unlock(listMode: listMode)
            return
        }

        busy = true
        defer { busy = false }

        do {
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

            listingLines = lines
            let entries = lines.filter { line in
                !line.isEmpty
                    && !line.hasPrefix("format=")
                    && !line.hasPrefix("combo=")
                    && !line.hasPrefix("root=")
                    && !line.hasPrefix("jti=")
                    && !line.hasPrefix("…")
            }.count
            detail = listMode == .root
                ? "Listed root — \(entries) vault entries."
                : "Listed recursively — \(entries) vault entries."
        } catch {
            detail = "List failed: \(error.localizedDescription)"
        }
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
        if unlockInFlight {
            detail = "Unlock already in progress…"
            return
        }
        unlockInFlight = true
        busy = true
        defer {
            busy = false
            unlockInFlight = false
        }
        let previousStatus = status
        status = .connecting

        if secretKey.isEmpty {
            secretKey = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.secretKeyAccount)) ?? ""
        }
        if password.isEmpty {
            password = (try? CredentialStore.readSharedOrLocal(account: AppIdentifiers.passwordAccount)) ?? ""
        }

        guard !password.isEmpty else {
            status = previousStatus == .unlocked ? .unlocked : .locked
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
            let netPrefs = AppPreferences.load()
            let proxyPassword = try? CredentialStore.readSharedOrLocal(
                account: AppIdentifiers.proxyPasswordAccount
            )
            store = S3ObjectStore(
                settings: S3Settings(
                    endpoint: endpoint,
                    region: snapshotSettings.region,
                    bucket: snapshotSettings.bucket,
                    accessKey: snapshotSettings.accessKey,
                    secretKey: snapshotSecret,
                    pathStyle: true
                ),
                configureSession: { netPrefs.applyProxy(to: $0, password: proxyPassword) }
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
            // Keep credentials in memory while unlocked so List / re-unlock still work if Keychain lags.
            // Clear them on lock().

            // Replace any previous session/store (new unlock always builds a fresh store).
            let previousStore = activeStore
            activeSession = session
            activeStore = store
            if let previousStore {
                if let s3 = previousStore as? S3ObjectStore {
                    try? await s3.shutdown()
                }
            }

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
            userWantsUnlocked = true
            status = .unlocked
            if !settings.isLocal {
                endpointReachable = true
                connectivityBanner = ""
            }
            if detail.hasPrefix("Unlocked, but save failed") == false {
                let entries = lines.filter { line in
                    !line.isEmpty
                        && !line.hasPrefix("format=")
                        && !line.hasPrefix("combo=")
                        && !line.hasPrefix("root=")
                        && !line.hasPrefix("jti=")
                        && !line.hasPrefix("…")
                }.count
                let base = snapshotSettings.isLocal
                    ? "Unlock succeeded (local vault)"
                    : "Unlock succeeded"
                detail = listMode == .none ? "\(base)." : "\(base) — \(entries) vault entries listed."
            }
            if bundledApp {
                // Keep Finder mounted as the normal unlocked state.
                Task { await self.mountAfterUnlock() }
            }
            return
        } catch {
            // Close the store we just created; leave any prior unlocked session alone.
            if let s3 = store as? S3ObjectStore {
                try? await s3.shutdown()
            }
            if activeSession == nil {
                status = .error
                jti = nil
                sessionUser = ""
                sessionLocation = ""
                listingLines = []
            } else {
                status = .unlocked
            }
            detail = error.localizedDescription
        }
    }

    func refreshTransfers() {
        transfer = TransferMetrics.load()
    }

    func resetTransferMetrics() {
        TransferMetrics.reset()
        refreshTransfers()
    }



    // MARK: - FUSE + rclone

    func mountSyncVolume() {
        guard isUnlocked, let session = activeSession else {
            detail = "Unlock the vault before mounting the sync volume."
            return
        }
        fuseMount.mount(session: session)
        detail = fuseMount.isMounted
            ? "Sync volume mounted at \(FuseMountController.preferredMountURL.path)"
            : (fuseMount.lastError ?? "Mounting sync volume…")
    }

    func unmountSyncVolume() {
        fuseMount.unmount()
        detail = "Sync volume unmounted."
    }

    func startRcloneBackupSync() {
        guard isUnlocked, let session = activeSession else {
            detail = "Unlock first."
            return
        }
        guard !backupSources.isEmpty else {
            detail = "Add at least one folder."
            return
        }
        let sources: [BackupSource]
        do {
            sources = try prepareBackupSourcesForSync(backupSources)
            try BackupPathOverlap.throwIfOverlapping(sources)
        } catch {
            detail = error.localizedDescription
            return
        }
        guard RcloneDriver.isAvailable else {
            detail = "rclone not found — brew install rclone"
            return
        }
        if !fuseMount.isMounted {
            fuseMount.mount(session: session)
        }
        rcloneLog = ""
        detail = "rclone sync into FUSE mount…"
        let mountPath = FuseMountController.preferredMountURL.path
        Task.detached { [weak self] in
            // Wait briefly for mount notification
            for _ in 0..<50 {
                let mounted = await MainActor.run { self?.fuseMount.isMounted ?? false }
                if mounted { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard await MainActor.run(body: { self?.fuseMount.isMounted ?? false }) else {
                await MainActor.run { self?.detail = self?.fuseMount.lastError ?? "FUSE mount did not come up" }
                return
            }
            var failures = 0
            for source in sources {
                do {
                    let code = try RcloneDriver.copy(
                        source: source.path,
                        fuseMount: mountPath,
                        vaultFolder: source.vaultFolderName
                    ) { chunk in
                        Task { @MainActor in
                            self?.rcloneLog.append(chunk)
                            if self?.rcloneLog.count ?? 0 > 8000 {
                                self?.rcloneLog = String(self?.rcloneLog.suffix(6000) ?? "")
                            }
                        }
                    }
                    if code != 0 { failures += 1 }
                } catch {
                    failures += 1
                    await MainActor.run {
                        self?.detail = error.localizedDescription
                    }
                }
            }
            await MainActor.run {
                self?.detail = failures == 0
                    ? "rclone finished into \(mountPath) (remote puts via FUSE)."
                    : "rclone finished with \(failures) failure(s) — see log."
            }
        }
    }

    // MARK: - Backup sources

    func persistBackupSources() {
        var store = BackupSourcesStore(sources: backupSources)
        do {
            try store.save()
        } catch {
            detail = "Could not save backup sources: \(error.localizedDescription)"
        }
    }

    /// Remount SMB sources (bookmark / NetFS) and refresh persisted paths before Sync.
    /// Fail-closed: throws if any SMB share cannot be mounted — never pretend the tree is empty.
    func prepareBackupSourcesForSync(_ sources: [BackupSource]) throws -> [BackupSource] {
        var prepared: [BackupSource] = []
        var changed = false
        for var source in sources {
            if source.isSMB {
                _ = try SMBBackupMount.ensureMounted(&source)
                if let idx = backupSources.firstIndex(where: { $0.id == source.id }),
                   backupSources[idx] != source
                {
                    backupSources[idx] = source
                    changed = true
                }
            } else {
                let url = URL(fileURLWithPath: source.path, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    throw SMBBackupMount.MountError.volumeUnavailable(source.path)
                }
            }
            prepared.append(source)
        }
        if changed {
            persistBackupSources()
        }
        return prepared
    }

    func addBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to sync into the vault (under Backups/)"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var softWarn: String?
        for url in panel.urls {
            let path = url.path
            // Deduplicate by resolved path when possible (parity with Windows Resolve).
            let resolved: String
            do { resolved = try BackupPathOverlap.resolve(path) }
            catch { resolved = path }
            if backupSources.contains(where: {
                (try? BackupPathOverlap.resolve($0.path)) == resolved || $0.path == path
            }) { continue }
            if softWarn == nil {
                softWarn = BackupPathOverlap.softWarnOnAdd(existing: backupSources, candidatePath: path)
            }
            var source = BackupSource(path: (try? BackupPathOverlap.resolve(path)) ?? path)
            // If the user picked an already-mounted network volume, stamp it as SMB when possible.
            if SMBBackupMount.looksLikeNetworkVolume(url) {
                source.kind = .smb
                source.bookmarkData = SMBBackupMount.makeBookmark(for: url)
            }
            backupSources.append(source)
        }
        persistBackupSources()
        if let softWarn {
            detail = softWarn
        }
    }

    /// Mount `smb://…`, optionally let the user pick a subfolder on the mounted volume, store password in Keychain.
    /// - Parameter promptForSubfolder: When true (default), shows Use share root / Choose folder after a successful mount.
    @discardableResult
    func addSMBShare(urlString: String, username: String?, password: String, promptForSubfolder: Bool = true) throws -> Bool {
        let normalized = try SMBSourceURL.normalize(urlString)
        if backupSources.contains(where: { $0.isSMB && $0.smbURL == normalized }) {
            detail = "That SMB share is already in the list."
            return false
        }
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = (user?.isEmpty == false) ? user : nil
        let mounted = try SMBBackupMount.mount(
            smbURLString: normalized,
            username: cleanUser,
            password: password,
            allowSystemUI: true
        )

        var selected = mounted
        if promptForSubfolder {
            let alert = NSAlert()
            alert.messageText = "SMB share mounted"
            alert.informativeText = "Mounted at \(mounted.path). Use the share root, or pick a subfolder inside the share. (macOS may have prompted to connect / allow Local Network.)"
            alert.addButton(withTitle: "Use share root")
            alert.addButton(withTitle: "Choose folder…")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn {
                // User cancelled after mount — do not add; leave the OS mount as-is.
                detail = "SMB mount left at \(mounted.path); source not added."
                return false
            }
            if response == .alertSecondButtonReturn {
                if let picked = SMBBackupMount.pickFolderUnderMountedShare(startingAt: mounted) {
                    selected = picked
                }
                // Cancelled panel → keep share root (one-click still works).
            }
        }

        var source = BackupSource(
            path: selected.path,
            kind: .smb,
            smbURL: normalized,
            smbUsername: cleanUser,
            bookmarkData: SMBBackupMount.makeBookmark(for: selected)
        )
        try SMBBackupMount.savePassword(password, for: source)
        let softWarn = BackupPathOverlap.softWarnOnAdd(existing: backupSources, candidatePath: source.path)
        backupSources.append(source)
        persistBackupSources()
        let pathNote = selected.path == mounted.path ? selected.path : "\(selected.path) (share \(normalized))"
        detail = softWarn ?? "Added SMB source \(normalized) → \(pathNote)"
        return true
    }

    func removeBackupSource(_ id: String) {
        if let removed = backupSources.first(where: { $0.id == id }), removed.isSMB {
            SMBBackupMount.deletePassword(for: removed)
            // Do not force-unmount — the user may have mounted the share outside the app.
        }
        backupSources.removeAll { $0.id == id }
        persistBackupSources()
    }

    func startBackupSync(sourceID: String? = nil) {
        guard isUnlocked, let session = activeSession else {
            detail = "Unlock the vault before syncing backups."
            return
        }
        let selected: [BackupSource]
        if let sourceID {
            guard let one = backupSources.first(where: { $0.id == sourceID }) else {
                detail = "That backup folder is no longer in the list."
                return
            }
            selected = [one]
        } else {
            guard !backupSources.isEmpty else {
                detail = "Add at least one folder to back up."
                return
            }
            selected = backupSources
        }
        let sources: [BackupSource]
        do {
            sources = try prepareBackupSourcesForSync(selected)
            // Soft-warn was at add time; Sync hard-fails on nested overlap (Windows parity).
            try BackupPathOverlap.throwIfOverlapping(sources)
        } catch {
            detail = error.localizedDescription
            return
        }
        let mode = AppPreferences.load().backupTransferMode
        if sources.count == 1, let one = sources.first {
            detail = mode == .sync
                ? "Syncing Backups/\(one.vaultFolderName)/ (puts + delete vault-only under that folder)…"
                : "Backing up Backups/\(one.vaultFolderName)/ via direct remote puts (no vault deletes)…"
        } else {
            detail = mode == .sync
                ? "Syncing all backup folders (puts + delete vault-only under each Backups/<folder>/)…"
                : "Backing up all folders into vault (Backups/…) via direct remote puts (no vault deletes)…"
        }
        backupSync.sync(sources: sources, session: session)
        watchBackupSyncForFinderRefresh()
    }

    func cancelBackupSync() {
        backupSync.cancel()
    }

    /// Backup/FUSE writes go through VaultSession, not the File Provider, so Finder
    /// keeps a stale empty `Backups/` until we poke the enumerator.
    func signalFinderRefresh() async {
        guard let domain = domain() else { return }
        guard let manager = NSFileProviderManager(for: domain) else { return }
        do {
            try await manager.signalEnumerator(for: .rootContainer)
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            // Best-effort; listing in the Vault tab still reflects remote truth.
        }
    }

    private func watchBackupSyncForFinderRefresh() {
        Task { [weak self] in
            guard let self else { return }
            var ticks = 0
            while await MainActor.run(body: { self.backupSync.isRunning }) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                ticks += 1
                if ticks % 2 == 0 { // ~every 6s
                    await self.signalFinderRefresh()
                }
            }
            await self.signalFinderRefresh()
            await MainActor.run {
                if case .finished(let files, let bytes) = self.backupSync.state {
                    let deleted = self.backupSync.filesDeleted
                    if deleted > 0 {
                        self.detail = "Finished — \(files) files, \(TransferSnapshot.formatBytes(bytes)); removed \(deleted) vault-only item(s). Source untouched. Refresh Finder (CryptoMako → Backups/) or tap List root."
                    } else {
                        self.detail = "Finished — \(files) files, \(TransferSnapshot.formatBytes(bytes)). Source untouched. Refresh Finder (CryptoMako → Backups/) or tap List root."
                    }
                }
            }
        }
    }

    /// Debug / DerivedData builds often leave the appex registered but **disabled**
    /// (`pluginkit` without a leading `+`). Mount then creates an empty CloudStorage
    /// folder and never enumerates. Re-enable before add(domain).
    @discardableResult
    func ensureFileProviderExtensionEnabled() -> String {
        let appex = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("CryptoMakoFileProvider.appex", isDirectory: true)
        var notes: [String] = []
        if let appex, FileManager.default.fileExists(atPath: appex.path) {
            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            add.arguments = ["-a", appex.path]
            add.standardOutput = Pipe()
            add.standardError = Pipe()
            try? add.run()
            add.waitUntilExit()
            notes.append("pluginkit -a → \(add.terminationStatus)")
        } else {
            notes.append("appex path missing under PlugIns")
        }
        let enable = Process()
        enable.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        enable.arguments = ["-e", "use", "-i", AppIdentifiers.extensionBundleID]
        enable.standardOutput = Pipe()
        enable.standardError = Pipe()
        try? enable.run()
        enable.waitUntilExit()
        notes.append("pluginkit -e use → \(enable.terminationStatus)")
        return notes.joined(separator: "; ")
    }

    func domain() -> NSFileProviderDomain? {
        guard let jti else { return nil }
        return NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(AppIdentifiers.domainIdentifier(jti: jti)),
            displayName: "CryptoMako"
        )
    }

    /// Default UX: unlocked vault should appear in Finder without an extra click.
    func mountAfterUnlock() async {
        guard bundledApp, isUnlocked else { return }
        await refreshMountState()
        if isMounted {
            await signalFinderRefresh()
            if !detail.lowercased().contains("mount") {
                detail = detail.hasSuffix(".") ? String(detail.dropLast()) + "; Finder mounted." : detail + " Finder mounted."
            }
            return
        }
        await mount()
    }

    func mount() async {
        guard isUnlocked else {
            detail = "Unlock the vault before Mount in Finder."
            return
        }
        guard let domain = domain() else {
            detail = "No vault id (jti) yet — Unlock again, then Mount in Finder."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let pluginNote = ensureFileProviderExtensionEnabled()
            // Remove domain first so CloudStorage leftovers are not FP-locked (.Trash Permission denied).
            if let existing = try? await NSFileProviderManager.domains() {
                for d in existing where Self.isCryptoMakoDomain(d) {
                    try? await NSFileProviderManager.remove(d)
                }
            }
            // Best-effort wipe of stale placeholders; ignore failure (huge .Trash trees may refuse).
            _ = Self.removeCloudStorageLeftover()
            try await NSFileProviderManager.add(domain)
            isMounted = true
            detail = "Mounted. Finder → Locations → CryptoMako. (\(pluginNote))"
            await refreshMountState()
            await signalFinderRefresh()
        } catch {
            // Keep vault unlocked — mount is independent of crypto session.
            // Setting .error here made Unlock→Mount-fail look like "locked again".
            detail = "Vault unlocked, but Finder mount failed: \(error.localizedDescription). Try Refresh Finder."
            await refreshMountState()
        }
    }

    /// Unmount → wipe leftover → remount so Finder re-lists MinIO (fixes empty ghost folders).
    func refreshFinderMount() async {
        guard isUnlocked else {
            detail = "Unlock before Refresh Finder."
            return
        }
        detail = "Refreshing Finder mount…"
        await forceUnmountForRefresh()
        _ = Self.removeCloudStorageLeftover()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await mount()
        if isMounted {
            detail = "Finder refreshed. Open CryptoMako under Locations — remote listing should repopulate."
        }
    }

    func unmount() async {
        guard !isUnmounting else { return }
        isUnmounting = true
        defer { isUnmounting = false }
        // Do not set `busy` for the whole drain — that greyed Mount/Unmount for up to 10 minutes.
        await unmountAllDomains(cleanupLeftoverFolder: true, waitForRemoteIdle: true)
    }

    /// Fast remount helper: tear down domains without waiting for backup uploads to finish.
    func forceUnmountForRefresh() async {
        guard !isUnmounting else { return }
        isUnmounting = true
        defer { isUnmounting = false }
        await unmountAllDomains(cleanupLeftoverFolder: false, waitForRemoteIdle: false)
    }

    /// Remove every CryptoMako File Provider domain, then delete the leftover
    /// `~/Library/CloudStorage/CryptoMako-CryptoMako` materialization so tools
    /// like rclone cannot keep writing after disconnect.
    func unmountAllDomains(cleanupLeftoverFolder: Bool, waitForRemoteIdle: Bool = true) async {
        // Drain remote puts first so disconnect does not abandon in-flight MinIO uploads
        // (POSIX writers may already have returned; the vault is still catching up).
        if waitForRemoteIdle {
            detail = "Unmounting — waiting briefly for remote uploads to quiet…"
            let drained = await TransferMetrics.waitUntilIdle(timeoutSeconds: 45, quietSeconds: 0.75) { [weak self] snap in
                Task { @MainActor in
                    guard let self else { return }
                    if snap.inFlight > 0 {
                        let name = snap.currentName.map { " — \($0)" } ?? ""
                        self.detail = "Waiting for \(snap.inFlight) remote upload\(snap.inFlight == 1 ? "" : "s")\(name)…"
                        self.refreshTransfers()
                    }
                }
            }
            if !drained {
                let left = TransferMetrics.load().inFlight
                detail = "Still \(left) remote upload\(left == 1 ? "" : "s") in flight; unmounting Finder anyway (uploads keep running)."
            }
        }

        var removed = 0
        var errors: [String] = []
        do {
            let domains = try await NSFileProviderManager.domains()
            for domain in domains where Self.isCryptoMakoDomain(domain) {
                do {
                    try await NSFileProviderManager.remove(domain)
                    removed += 1
                } catch {
                    errors.append("\(domain.identifier.rawValue): \(error.localizedDescription)")
                }
            }
        } catch {
            errors.append(error.localizedDescription)
        }

        var cleaned = false
        if cleanupLeftoverFolder {
            cleaned = Self.removeCloudStorageLeftover()
        }

        await refreshMountState()

        if errors.isEmpty {
            detail = removed == 0 && !cleaned
                ? "Unmounted (no CryptoMako domain registered)."
                : "Unmounted\(removed > 0 ? " (\(removed) domain\(removed == 1 ? "" : "s"))" : "")\(cleaned ? "; removed local CloudStorage leftover" : "")."
            isMounted = false
        } else {
            status = .error
            detail = "Unmount/cleanup issues: \(errors.joined(separator: "; "))"
        }
    }

    static func isCryptoMakoDomain(_ domain: NSFileProviderDomain) -> Bool {
        domain.displayName == "CryptoMako"
            || domain.identifier.rawValue.lowercased().contains("cryptomako")
    }

    /// Best-effort delete of the Finder materialization folder. Safe after domain remove;
    /// vault-backed placeholders may still refuse until the domain is gone.
    @discardableResult
    /// Permanently delete a top-level vault item by cleartext name (recursive).
    /// Prefer this over Finder Trash for huge folders — no Error -36 timeout.
    func deleteRootItem(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            detail = "Enter a root folder or file name to delete."
            return
        }
        guard let session = activeSession, isUnlocked else {
            detail = "Unlock the vault before deleting."
            return
        }
        busy = true
        defer { busy = false }
        detail = "Deleting \(trimmed) from vault (remote)…"
        do {
            let kids = try await session.list(dirId: "")
            guard let node = kids.first(where: { $0.cleartextName == trimmed }) else {
                detail = "No root item named \(trimmed)."
                return
            }
            final class Counter: @unchecked Sendable {
                private let lock = NSLock()
                private var value = 0
                @discardableResult func inc() -> Int {
                    lock.lock(); defer { lock.unlock() }
                    value += 1
                    return value
                }
                var current: Int { lock.lock(); defer { lock.unlock() }; return value }
            }
            let counter = Counter()
            try await session.deleteNode(node, recursive: true) { [trimmed] in
                let n = counter.inc()
                if n == 1 || n % 25 == 0 {
                    Task { @MainActor in
                        self.detail = "Deleting \(trimmed)… \(n) remote objects removed"
                    }
                }
            }
            detail = "Deleted \(trimmed) (\(counter.current) remote objects). Refresh Finder or List root."
            await refreshListing(listMode: .root)
            await signalFinderRefresh()
        } catch {
            detail = "Delete failed: \(error.localizedDescription)"
            // Stay unlocked — delete errors must not look like Lock.
        }
    }

    static func removeCloudStorageLeftover() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/CryptoMako-CryptoMako", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Corrupted domain `.Trash` (stale NFS / 65535 ghosts) makes Finder Move-to-Trash
        // fail with Error -36 *before* the extension runs. Always try it first, including
        // hidden children — the old [.skipsHiddenFiles] fallback left `.Trash` forever.
        let trash = url.appendingPathComponent(".Trash", isDirectory: true)
        if FileManager.default.fileExists(atPath: trash.path) {
            try? FileManager.default.removeItem(at: trash)
            // If recursive remove fails on stale handles, rename aside so remount is clean.
            if FileManager.default.fileExists(atPath: trash.path) {
                let quarantine = url.appendingPathComponent(
                    ".Trash-stale-\(Int(Date().timeIntervalSince1970))",
                    isDirectory: true
                )
                try? FileManager.default.moveItem(at: trash, to: quarantine)
            }
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // Partial trees — try *all* children including hidden (.Trash, .DS_Store).
            if let kids = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                for child in kids {
                    try? FileManager.default.removeItem(at: child)
                }
            }
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Reconcile Finder-mount lamp with registered File Provider domains.
    func refreshMountState() async {
        let domains: [NSFileProviderDomain]
        do {
            domains = try await NSFileProviderManager.domains()
        } catch {
            // API unavailable or denied — keep last known value.
            return
        }
        if let jti {
            let want = AppIdentifiers.domainIdentifier(jti: jti)
            isMounted = domains.contains { $0.identifier.rawValue == want }
        } else {
            isMounted = domains.contains {
                $0.displayName == "CryptoMako"
                    || $0.identifier.rawValue.lowercased().contains("cryptomako")
            }
        }
    }

    // MARK: - S3 connectivity + auto-reconnect

    func onAutoReconnectChanged() {
        save(persistSecrets: false)
        if settings.autoReconnect {
            userWantsUnlocked = true
            Task { await attemptAutoUnlock(reason: "preference") }
        }
        startConnectivityMonitor()
    }

    func startConnectivityMonitor() {
        connectivityTask?.cancel()
        connectivityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeEndpointOnce()
                try? await Task.sleep(nanoseconds: 20_000_000_000) // 20s
            }
        }
    }

    func stopConnectivityMonitor() {
        connectivityTask?.cancel()
        connectivityTask = nil
    }

    @MainActor
    private func probeEndpointOnce() async {
        if settings.isLocal {
            if endpointReachable != nil || !connectivityBanner.isEmpty {
                endpointReachable = nil
                connectivityBanner = ""
            }
            lastReachable = nil
            return
        }
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, URL(string: endpoint) != nil else {
            endpointReachable = nil
            return
        }

        let ok = await S3EndpointProbe.isReachable(endpointURLString: endpoint)
        let previous = lastReachable
        lastReachable = ok
        endpointReachable = ok

        if ok {
            if previous == false {
                connectivityBanner = ""
                detail = "S3 endpoint reachable again."
                if settings.autoReconnect, userWantsUnlocked, !isUnlocked, !busy {
                    await attemptAutoUnlock(reason: "reconnect")
                }
            } else if connectivityBanner.lowercased().contains("no connectivity") {
                connectivityBanner = ""
            }
        } else {
            let message = "No connectivity to S3 endpoint (\(endpoint)). Check VPN or internet."
            connectivityBanner = message
            if previous != false {
                // Transition into outage — surface once in detail.
                detail = message
            }
        }
    }

    @MainActor
    private func attemptAutoUnlock(reason: String) async {
        guard settings.autoReconnect, userWantsUnlocked, !isUnlocked, !busy else { return }
        if !settings.isLocal, endpointReachable == false { return }
        detail = reason == "reconnect"
            ? "Reconnecting to vault…"
            : "Automatic unlock…"
        let ok = await unlockFromMenu()
        if !ok, status != .unlocked {
            // unlockFromMenu already set detail; keep connectivity banner if any
        }
    }


}
