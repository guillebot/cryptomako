import CryptoMakoVault
import Foundation

@MainActor
final class FuseMountController: ObservableObject {
    static let shared = FuseMountController()

    static var preferredMountURL: URL {
        URL(fileURLWithPath: "/Volumes/CryptoMakoSync", isDirectory: true)
    }

    static var macFUSEInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Filesystems/macfuse.fs")
            || FileManager.default.fileExists(atPath: "/Library/Frameworks/macFUSE.framework")
    }

    @Published private(set) var isMounted: Bool = false
    @Published private(set) var lastError: String?

    private var host: CryptoMakoFuseHost?
    private var fuseDelegate: VaultFuseDelegate?
    private var observers: [NSObjectProtocol] = []

    var statusSummary: String {
        var parts: [String] = []
        parts.append(Self.macFUSEInstalled ? "macFUSE installed" : "macFUSE missing")
        parts.append(RcloneDriver.isAvailable ? RcloneDriver.versionLine : "rclone missing (brew install rclone)")
        parts.append(isMounted ? "mounted at \(Self.preferredMountURL.path)" : "not mounted")
        if let lastError { parts.append(lastError) }
        return parts.joined(separator: " · ")
    }

    func mount(session: VaultSession) {
        guard Self.macFUSEInstalled else {
            lastError = "Install macFUSE from https://macfuse.github.io"
            return
        }
        if isMounted { return }

        clearObservers()

        let bridge = VaultFuseBridge(session: session)
        let del = VaultFuseDelegate(bridge: bridge)
        let host = CryptoMakoFuseHost(vaultFS: del)
        self.fuseDelegate = del
        self.host = host

        let path = Self.preferredMountURL.path
        let options = [
            "volname=CryptoMakoSync",
            "fsname=CryptoMakoSync",
            "local",
            "allow_recursion",
            "noappledouble",
            "noapplexattr",
        ]

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: CryptoMakoFuseHost.didMountNotification(),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMounted = true
                self?.lastError = nil
            }
        })
        observers.append(center.addObserver(
            forName: CryptoMakoFuseHost.mountFailedNotification(),
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.isMounted = false
                let key = CryptoMakoFuseHost.errorUserInfoKey()
                let err = (note.userInfo?[key] as? NSError)?.localizedDescription
                self?.lastError = err ?? "FUSE mount failed"
                self?.host = nil
                self?.fuseDelegate = nil
            }
        })
        observers.append(center.addObserver(
            forName: CryptoMakoFuseHost.didUnmountNotification(),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMounted = false
                self?.host = nil
                self?.fuseDelegate = nil
            }
        })

        host.mount(atPath: path, options: options)
    }

    func unmount() {
        host?.unmount()
        host = nil
        fuseDelegate = nil
        isMounted = false
        clearObservers()
    }

    private func clearObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
}
