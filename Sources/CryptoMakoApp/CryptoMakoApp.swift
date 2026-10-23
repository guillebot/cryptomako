import AppKit
import CryptoMakoShared
import os
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
            // Single-window app: drop File > New Window (⌘N). Extra WindowGroup
            // instances are not kept alive by MainWindowController.
            CommandGroup(replacing: .newItem) {}
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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    delegate.model.openSettings()
                    delegate.showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
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
        // Agents / scripts: `post net.gschimmel.cryptomako.cancelBackupSync` to stop Sync.
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("net.gschimmel.cryptomako.cancelBackupSync"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.cancelBackupSync()
            }
        }
        // Poll so tooltip stays live even if a notification is missed across processes.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshTransfers()
            }
        }
        // SwiftUI shows the WindowGroup window itself at launch; MainWindowAccessor adopts it.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Returning true lets SwiftUI build a fresh WindowGroup window, so only do that when
    /// there is no main window to bring back; otherwise a hidden window would get a twin.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !MainWindowController.shared.bringToFront()
    }

    @MainActor
    func showMainWindow() {
        MainWindowController.shared.show()
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

/// Owns the app's main window and keeps it alive. NSApp.windows also holds the status item's
/// NSStatusBarWindow and OS helpers (TextInputUI) that refuse key status, so it is never indexed
/// by position. Closing hides the window instead of letting SwiftUI destroy it: an accessory app
/// with no Dock icon has no reliable way to get a destroyed WindowGroup window back.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    /// Pinned so edits to the scene's root modifier chain no longer orphan the saved frame.
    static let frameAutosaveName = "CryptoMakoMainWindow"

    private static let log = Logger(subsystem: "net.gschimmel.cryptomako", category: "main-window")

    private weak var window: NSWindow?
    /// Whatever delegate SwiftUI installed; every message we do not handle is forwarded to it.
    /// NSWindow holds its delegate weakly, so SwiftUI keeps owning that object.
    nonisolated(unsafe) private weak var forwardedDelegate: NSWindowDelegate?
    private var frameConfigured = false

    /// Called by MainWindowAccessor once the SwiftUI content is attached to a window.
    func adopt(_ candidate: NSWindow) {
        if let window, window !== candidate { return }
        window = candidate
        installDelegate(on: candidate)
        if !frameConfigured {
            frameConfigured = true
            configureFrame(candidate)
        }
    }

    /// Brings the main window front. If none exists yet, retries once on the next run loop turn,
    /// then falls back to a Dock icon: clicking it sends a reopen event that SwiftUI answers
    /// with a new window, which MainWindowAccessor adopts.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if bringToFront() { return }
        DispatchQueue.main.async { [self] in
            if bringToFront() { return }
            Self.log.error("No main window to show; switching to regular activation policy")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Orders the main window front if one exists. Never calls back into reopen handling.
    @discardableResult
    func bringToFront() -> Bool {
        let tracked = window.map { [$0] } ?? []
        let candidates = (tracked + NSApp.windows).map(AppKitWindowCandidate.init)
        guard let target = MainWindowSelection.selectMainWindow(from: candidates)?.window else {
            return false
        }
        adopt(target)
        target.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }
        sender.orderOut(nil)
        if NSApp.activationPolicy() != .accessory {
            // Async: flipping policy while the window is still key can deactivate the app mid-close.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { installDelegate(on: window) }
        forwardedDelegate?.windowDidBecomeKey?(notification)
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardedDelegate?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let forwardedDelegate, forwardedDelegate.responds(to: aSelector) {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    /// SwiftUI may (re)assign the delegate after the accessor fires; re-asserting on key and on
    /// every show keeps the close interception in place without dropping SwiftUI's delegate.
    private func installDelegate(on window: NSWindow) {
        guard window === self.window, window.delegate !== self else { return }
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    private func configureFrame(_ window: NSWindow) {
        let pinned = Self.frameAutosaveName
        let derived = window.frameAutosaveName
        if derived != pinned {
            let hasPinnedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(pinned)") != nil
            if !hasPinnedFrame, !derived.isEmpty {
                // First run with the pinned name: carry over the position SwiftUI saved.
                _ = window.setFrameUsingName(derived)
            }
            if !window.setFrameAutosaveName(pinned) {
                Self.log.error("Could not pin frame autosave name")
            }
            if hasPinnedFrame {
                _ = window.setFrameUsingName(pinned)
            }
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let validated = MainWindowFrame.validatedFrame(
            window.frame,
            screens: screens,
            mainScreen: screens.first
        )
        if validated != window.frame {
            Self.log.info("Corrected restored main window frame")
            window.setFrame(validated, display: true)
        }
        window.saveFrame(usingName: window.frameAutosaveName)
    }
}

private struct AppKitWindowCandidate: MainWindowCandidate {
    let window: NSWindow
    let canBecomeMain: Bool
    let canBecomeKey: Bool
    let hasContentViewController: Bool

    @MainActor
    init(_ window: NSWindow) {
        self.window = window
        canBecomeMain = window.canBecomeMain
        canBecomeKey = window.canBecomeKey
        hasContentViewController = window.contentViewController != nil
    }
}

/// Hands the hosting NSWindow to MainWindowController. Lives inside ContentView rather than on the
/// scene so the WindowGroup root type, which SwiftUI derives the legacy frame key from, is unchanged.
struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowReportingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Next turn: SwiftUI finishes configuring the window (delegate, restored frame) first.
            DispatchQueue.main.async {
                MainWindowController.shared.adopt(window)
            }
        }
    }
}

enum BrandIcon {
    private static let cached: NSImage? = load()
    private static let statusBarSize = NSSize(width: 24, height: 24)
    /// Precomputed once — TIFF + opaque-pixel walk must never run per menu rebuild.
    private static let cachedTemplateStatusBar: NSImage = makeTemplateStatusBarImage()

    static var image: NSImage? { cached }

    /// Menu-bar sized template image (adapts to dark/light status bar).
    static var statusBarImage: NSImage {
        statusBarImage(indicatorColor: nil)
    }

    /// Menu-bar icon with an optional colored status badge (non-template so the color stays visible).
    static func statusBarImage(indicatorColor: NSColor?) -> NSImage {
        let size = statusBarSize
        let base = cachedTemplateStatusBar

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
            let diameter: CGFloat = 8.0
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
        cachedTemplateStatusBar
    }

    private static func makeTemplateStatusBarImage() -> NSImage {
        let size = statusBarSize
        // Prefer the canonical cyan-only menu-bar template (white bucket + padlock).
        if let source = loadNamed("MenuBarTemplate") ?? cached {
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            let inset: CGFloat = 0.75
            let dest = NSRect(
                x: inset,
                y: inset,
                width: size.width - inset * 2,
                height: size.height - inset * 2
            )
            let from = opaqueContentRect(of: source) ?? NSRect(origin: .zero, size: source.size)
            // Aspect-fit the opaque mark into the status-item slot.
            let fitted = aspectFit(from.size, into: dest)
            source.draw(
                in: fitted,
                from: from,
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

    /// Bounding rect of non-near-transparent pixels, or nil if unavailable.
    private static func opaqueContentRect(of image: NSImage) -> NSRect? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.bitmapData
        else { return nil }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let spp = rep.samplesPerPixel
        let bpp = rep.bitsPerPixel / 8
        let rowBytes = rep.bytesPerRow
        let hasAlpha = rep.hasAlpha
        guard w > 0, h > 0, hasAlpha, bpp > 0, spp > 0 else { return nil }

        // Alpha is the last sample for non-planar RGBA/WA bitmaps.
        let alphaOffset = spp - 1
        var minX = w
        var minY = h
        var maxX = 0
        var maxY = 0
        var found = false

        for y in 0..<h {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<w {
                let alpha = row.advanced(by: x * bpp + alphaOffset).pointee
                guard alpha > 10 else { continue }
                found = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard found else { return nil }

        // NSImage draws with a bottom-left origin; bitmap rows are top-down.
        let scaleX = image.size.width / CGFloat(w)
        let scaleY = image.size.height / CGFloat(h)
        let bottom = CGFloat(h - 1 - maxY)
        return NSRect(
            x: CGFloat(minX) * scaleX,
            y: bottom * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }

    private static func aspectFit(_ content: NSSize, into dest: NSRect) -> NSRect {
        guard content.width > 0, content.height > 0 else { return dest }
        let scale = min(dest.width / content.width, dest.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return NSRect(
            x: dest.midX - w / 2,
            y: dest.midY - h / 2,
            width: w,
            height: h
        )
    }

    private static func loadNamed(_ name: String) -> NSImage? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return nil
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
