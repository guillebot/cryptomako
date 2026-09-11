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
    }
}

/// Running from SwiftPM there is no app bundle, so the window would open behind
/// other apps with no Dock presence until the M2 Xcode target exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
