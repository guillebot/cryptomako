import AppKit
import Combine
import SwiftUI

/// Menu-bar (status item) presence for CryptoMako.
@MainActor
final class StatusItemController {
    private let model: VaultAppModel
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var showWindowHandler: () -> Void

    init(model: VaultAppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindowHandler = showWindow
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.toolTip = "CryptoMako"
            button.setAccessibilityTitle("CryptoMako")
        }
        statusItem = item
        rebuildMenu()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer one turn so @Published values are settled.
                DispatchQueue.main.async {
                    self?.rebuildMenu()
                }
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

    func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

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

        let showItem = NSMenuItem(
            title: "Open CryptoMako…",
            action: #selector(showWindow(_:)),
            keyEquivalent: "o"
        )
        showItem.keyEquivalentModifierMask = [.command]
        showItem.target = self
        menu.addItem(showItem)

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

        let quitItem = NSMenuItem(
            title: "Quit CryptoMako",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.toolTip = "CryptoMako — \(model.status.rawValue)"
        updateStatusItemImage()
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

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
