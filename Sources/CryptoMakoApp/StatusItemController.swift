import AppKit
import CryptoMakoShared
import Combine
import SwiftUI

/// Menu-bar (status item) presence for CryptoMako.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: VaultAppModel
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var showWindowHandler: () -> Void

    /// Last structural snapshot — full NSMenu rebuild only when these change
    /// (or when the menu is about to open). Sync counter ticks update chrome only.
    private struct MenuStructure: Equatable {
        var vaultStatus: VaultAppModel.Status
        var detailShown: Bool
        var isUnlocked: Bool
        var busy: Bool
        var syncRunning: Bool
        var transferInFlight: Int
        var transferFailed: Int
    }

    private var lastStructure: MenuStructure?

    init(model: VaultAppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindowHandler = showWindow
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.toolTip = "CryptoMako"
            button.setAccessibilityTitle("CryptoMako")
        }
        statusItem = item
        rebuildMenu()

        // Vault model: structural changes (unlock/lock/status) need a full rebuild;
        // transfer ticks only need tooltip / indicator refresh.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleModelChange()
            }
            .store(in: &cancellables)
        // BackupSyncEngine is a separate ObservableObject; without this the menu
        // never learns Sync started/stopped and Cancel Sync would not appear.
        // progressEpoch / counter publishes must NOT rebuild the full NSMenu.
        model.backupSync.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSyncChange()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemImage()
            }
        }
    }

    private func currentStructure() -> MenuStructure {
        let detail = model.detail
        let showDetail = !detail.isEmpty && (model.status == .error || model.status == .connecting)
        return MenuStructure(
            vaultStatus: model.status,
            detailShown: showDetail,
            isUnlocked: model.isUnlocked,
            busy: model.busy,
            syncRunning: model.backupSync.isRunning,
            transferInFlight: model.transfer.inFlight,
            transferFailed: model.transfer.failedPuts
        )
    }

    private func handleModelChange() {
        let structure = currentStructure()
        if structure != lastStructure {
            rebuildMenu()
        } else {
            updateChrome()
        }
    }

    private func handleSyncChange() {
        let structure = currentStructure()
        if structure.syncRunning != lastStructure?.syncRunning {
            rebuildMenu()
        } else {
            // Walk/Put/progressEpoch ticks — tooltip + lamp only.
            updateChrome()
        }
    }

    /// Cheap status-item updates that avoid tearing down NSMenu on every Sync tick.
    private func updateChrome() {
        guard let statusItem else { return }
        let xfer = model.transfer
        let sync = model.backupSync
        var tip = xfer.tooltip + "\n\nVault: \(model.status.rawValue)"
        if sync.isRunning {
            let phase = sync.phaseLabel.isEmpty ? "Syncing" : sync.phaseLabel
            tip += "\nBackup Sync: \(phase) · \(sync.progressPercentLabel)"
            tip += "\n\(sync.filesDone)/\(max(sync.filesDiscovered, sync.filesDone)) files"
        }
        statusItem.button?.toolTip = tip
        updateStatusItemImage()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Populate in place right before open so transfer lines / Cancel stay
        // fresh without paying full rebuild cost on every Sync counter tick.
        populateMenu(menu)
        lastStructure = currentStructure()
        updateChrome()
    }

    func rebuildMenu() {
        guard let statusItem else { return }
        let menu = statusItem.menu ?? NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
        lastStructure = currentStructure()
        updateChrome()
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusItemMenu = NSMenuItem()
        statusItemMenu.attributedTitle = NSAttributedString(
            string: model.status.menuLabel,
            attributes: [
                .foregroundColor: model.status.menuStatusColor,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        // Keep enabled so AppKit does not wash out the attributed color; nil action = non-interactive.
        statusItemMenu.isEnabled = true
        statusItemMenu.action = nil
        menu.addItem(statusItemMenu)

        if !model.detail.isEmpty, model.status == .error || model.status == .connecting {
            let detailItem = NSMenuItem(
                title: truncate(model.detail, limit: 64),
                action: nil,
                keyEquivalent: ""
            )
            detailItem.isEnabled = false
            menu.addItem(detailItem)
        }

        menu.addItem(.separator())

        let showItem = NSMenuItem(
            title: "Open CryptoMako…",
            action: #selector(showWindow(_:)),
            keyEquivalent: "o"
        )
        showItem.keyEquivalentModifierMask = [.command]
        showItem.target = self
        menu.addItem(showItem)

        if model.backupSync.isRunning {
            let cancelSync = NSMenuItem(
                title: "Cancel Backup Sync",
                action: #selector(cancelBackupSync(_:)),
                keyEquivalent: "."
            )
            cancelSync.keyEquivalentModifierMask = [.command]
            cancelSync.target = self
            menu.addItem(cancelSync)
        }

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About CryptoMako",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        // Transfer summary in the menu (remote commits only).
        let xfer = model.transfer
        menu.addItem(.separator())
        let xferHeader = NSMenuItem(title: "Remote transfers", action: nil, keyEquivalent: "")
        xferHeader.isEnabled = false
        menu.addItem(xferHeader)
        let liveRate = xfer.liveUploadBytesPerSecond()
        let bandwidthLine = liveRate > 0
            ? "Bandwidth: \(TransferSnapshot.formatRate(liveRate))"
            : "Bandwidth: —"
        for line in [
            xfer.inFlight > 0
                ? "In flight: \(xfer.inFlight)\(xfer.currentName.map { " — \($0)" } ?? "")"
                : "In flight: 0",
            "Uploaded: \(xfer.completedPuts) files (\(TransferSnapshot.formatBytes(xfer.bytesUploaded)))",
            bandwidthLine,
            xfer.failedPuts > 0 ? "Failed: \(xfer.failedPuts)" : nil,
        ].compactMap({ $0 }) {
            let item = NSMenuItem(title: truncate(line, limit: 72), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if model.isUnlocked {
            let lockItem = NSMenuItem(
                title: "Lock",
                action: #selector(lockVault(_:)),
                keyEquivalent: ""
            )
            lockItem.target = self
            lockItem.isEnabled = !model.busy
            menu.addItem(lockItem)
        } else {
            let unlockItem = NSMenuItem(
                title: "Unlock",
                action: #selector(unlockVault(_:)),
                keyEquivalent: ""
            )
            unlockItem.target = self
            unlockItem.isEnabled = !model.busy
            menu.addItem(unlockItem)
        }

        let quitItem = NSMenuItem(
            title: "Quit CryptoMako",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func updateStatusItemImage() {
        statusItem?.button?.image = BrandIcon.statusBarImage(
            indicatorColor: model.status.statusItemIndicator
        )
    }

    private func truncate(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    @objc private func unlockVault(_ sender: Any?) {
        Task { @MainActor in
            let ok = await model.unlockFromMenu()
            if !ok {
                showWindowHandler()
            }
            rebuildMenu()
        }
    }

    @objc private func lockVault(_ sender: Any?) {
        model.lock()
        rebuildMenu()
    }

    @objc private func showWindow(_ sender: Any?) {
        showWindowHandler()
    }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "CryptoMako",
            .applicationVersion: AppVersion.marketing,
        ]
        if let build = AppVersion.build {
            options[.version] = build
        }
        if let icon = BrandIcon.image {
            options[.applicationIcon] = icon
        }
        options[.credits] = NSAttributedString(
            string: "Version \(AppVersion.displayString)\nAGPLv3"
        )
        showWindowHandler()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func checkUpdates(_ sender: Any?) {
        Task { @MainActor in
            await UpdateChecker.checkAndPresent()
        }
    }

    @objc private func cancelBackupSync(_ sender: Any?) {
        model.cancelBackupSync()
        rebuildMenu()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
