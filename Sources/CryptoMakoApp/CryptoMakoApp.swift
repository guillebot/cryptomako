import AppKit
import SwiftUI

@main
struct CryptoMakoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("CryptoMako") {
            ContentView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CryptoMako") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .applicationName: "CryptoMako",
                    ]
                    if let icon = BrandIcon.image {
                        options[.applicationIcon] = icon
                    }
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
        }
    }
}

/// Running from SwiftPM there is no `.app` bundle with an asset catalog, so we
/// set the Dock icon from the embedded `AppIcon.png` resource.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = BrandIcon.image {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum BrandIcon {
    private static let cached: NSImage? = load()

    static var image: NSImage? { cached }

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
