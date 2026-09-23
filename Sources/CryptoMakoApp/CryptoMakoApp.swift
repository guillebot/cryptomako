import AppKit
import CryptoMakoShared
import SwiftUI

@main
struct CryptoMakoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("CryptoMako") {
            ContentView()
                .environmentObject(delegate.model)
                .frame(minWidth: 560, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CryptoMako") {
                    delegate.showAbout()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { @MainActor in
                        await UpdateChecker.checkAndPresent()
                    }
                }
            }
        }
    }
}

/// Menu-bar accessory app: status item stays up after the window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = VaultAppModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--cleanup-mount") {
            Task { @MainActor in
                await model.unmountAllDomains(cleanupLeftoverFolder: true)
                print(model.detail)
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--refresh-finder") {
            // Remount after normal load/auto-unlock below (do not return early).
            Task { @MainActor in
                for _ in 0..<40 {
                    if model.isUnlocked { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if !model.isUnlocked {
                    _ = await model.unlockFromMenu()
                }
                await model.refreshFinderMount()
                print(model.detail)
            }
        }
        if CommandLine.arguments.contains("--start-backup-sync") {
            Task { @MainActor in
                for _ in 0..<40 {
                    if model.isUnlocked { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if !model.isUnlocked {
                    _ = await model.unlockFromMenu()
                }
                model.startBackupSync()
                print("backup-sync started: \(model.detail)")
            }
        }
        // Accessory: Dock icon hidden; window opens from the status item.
        NSApp.setActivationPolicy(.accessory)
        if let icon = BrandIcon.image {
            NSApp.applicationIconImage = icon
        }

        let controller = StatusItemController(model: model) { [weak self] in
            self?.showMainWindow()
        }
        controller.install()
        statusItemController = controller

        model.load()
        model.refreshTransfers()
        DistributedNotificationCenter.default.addObserver(
            forName: TransferMetrics.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshTransfers()
            }
        }
        // Agents / scripts: `post net.gschimmel.cryptomako.refreshFinder` to remount.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("net.gschimmel.cryptomako.refreshFinder"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.model.refreshFinderMount()
            }
        }
        // Agents / scripts: `post net.gschimmel.cryptomako.startBackupSync` to run Sync all.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("net.gschimmel.cryptomako.startBackupSync"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.model.isUnlocked {
                    _ = await self.model.unlockFromMenu()
                }
                self.model.startBackupSync()
            }
        }
        // Poll so tooltip stays live even if a notification is missed across processes.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshTransfers()
            }
        }
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @MainActor
    func showMainWindow() {
        // Accessory policy can leave WindowGroup unmaterialized; briefly go regular
        // so SwiftUI creates the scene, then order it front.
        if NSApp.activationPolicy() == .accessory, NSApp.windows.isEmpty {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        // Fallback: ask AppKit to reopen (creates WindowGroup for accessory apps).
        if NSApp.windows.isEmpty {
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @MainActor
    func showAbout() {
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
        showMainWindow()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

enum BrandIcon {
    private static let cached: NSImage? = load()
    private static let statusBarSize = NSSize(width: 18, height: 18)

    static var image: NSImage? { cached }

    /// Menu-bar sized template image (adapts to dark/light status bar).
    static var statusBarImage: NSImage {
        statusBarImage(indicatorColor: nil)
    }

    /// Menu-bar icon with an optional colored status badge (non-template so the color stays visible).
    static func statusBarImage(indicatorColor: NSColor?) -> NSImage {
        let size = statusBarSize
        let base = templateStatusBarImage()

        guard let indicatorColor else {
            return base
        }

        let composed = NSImage(size: size, flipped: false) { bounds in
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let tint = isDark ? NSColor.white : NSColor.black

            // Draw the template icon tinted for the current menu-bar appearance.
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            base.draw(
                in: NSRect(origin: .zero, size: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            tint.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: bounds)

            // Small status dot (bottom-trailing) with a contrasting halo.
            let diameter: CGFloat = 6.5
            let pad: CGFloat = 0.5
            let haloRect = NSRect(
                x: bounds.maxX - diameter - pad - 1,
                y: pad,
                width: diameter + 2,
                height: diameter + 2
            )
            let dotRect = haloRect.insetBy(dx: 1, dy: 1)

            (isDark ? NSColor.black : NSColor.white).withAlphaComponent(0.95).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            indicatorColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        composed.isTemplate = false
        return composed
    }

    private static func templateStatusBarImage() -> NSImage {
        if let source = cached {
            let size = statusBarSize
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy,
                fraction: 1.0
            )
            scaled.unlockFocus()
            scaled.isTemplate = true
            return scaled
        }
        let symbol = NSImage(systemSymbolName: "lock.rectangle.stack.fill", accessibilityDescription: "CryptoMako")
            ?? NSImage(size: statusBarSize)
        symbol.isTemplate = true
        return symbol
    }

    static var swiftUIImage: Image {
        if let ns = cached {
            return Image(nsImage: ns)
        }
        return Image(systemName: "lock.rectangle.stack.fill")
    }

    private static func load() -> NSImage? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        #endif
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return nil
    }
}
