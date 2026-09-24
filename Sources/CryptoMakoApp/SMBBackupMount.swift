import AppKit
import CryptoMakoShared
import Foundation
import NetFS
import OSLog

/// Mount / remount SMB Backup Sync sources via macOS (`NetFS` / `NSWorkspace` / `/Volumes`), never an embedded SMB client.
enum SMBBackupMount {
    enum MountError: Error, LocalizedError {
        case invalidURL(String)
        case mountFailed(String)
        case mountTimedOut(String)
        case volumeUnavailable(String)
        case volumeLost(String)
        case missingCredentials
        case bookmarkFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL(let s):
                return s
            case .mountFailed(let s):
                return "Could not mount SMB share: \(s)"
            case .mountTimedOut(let s):
                return "Timed out waiting for SMB mount: \(s). Complete the system Connect dialog (or mount in Finder), check Local Network privacy for CryptoMako, then retry."
            case .volumeUnavailable(let s):
                return "SMB source unavailable: \(s). Mount the share and retry Sync (fail-closed — nothing was treated as an empty tree)."
            case .volumeLost(let s):
                return "SMB volume disappeared during Sync: \(s). Sync stopped fail-closed (no wipe / no silent empty-tree success)."
            case .missingCredentials:
                return "SMB password not found in Keychain. Remove the source and add it again."
            case .bookmarkFailed:
                return "Could not create a security-scoped bookmark for the mounted SMB path."
            }
        }
    }

    private static let log = Logger(subsystem: "net.gschimmel.cryptomako", category: "smb-backup")

    /// How long to wait for `/Volumes` after opening `smb://` via the system UI.
    private static let systemConnectPollTimeout: TimeInterval = 75
    private static let systemConnectPollInterval: TimeInterval = 0.5

    // MARK: - Public API

    /// Ensure an SMB `BackupSource` is mounted and reachable. Updates `path` / `bookmarkData` in place when remounted.
    @discardableResult
    static func ensureMounted(_ source: inout BackupSource) throws -> URL {
        guard source.kind == .smb else {
            let url = URL(fileURLWithPath: source.path, isDirectory: true)
            guard isReachableDirectory(url) else {
                throw MountError.volumeUnavailable(source.path)
            }
            return url
        }

        let smb = try normalizedSMBURL(from: source)
        if let existing = tryResolveExisting(source: source) {
            source.path = existing.path
            if source.bookmarkData == nil {
                source.bookmarkData = makeBookmark(for: existing)
            }
            return existing
        }

        let password = try loadPassword(for: source)
        // Remount may show system Connect UI (AllowUI / NSWorkspace) but always with a poll timeout — never wait forever.
        let mounted = try mount(
            smbURLString: smb,
            username: source.smbUsername,
            password: password,
            allowSystemUI: true
        )
        // Prefer keeping a deeper previously-picked path when it still exists under the remounted volume.
        if source.path.hasPrefix("/Volumes/"),
           isReachableDirectory(URL(fileURLWithPath: source.path, isDirectory: true)) {
            let kept = URL(fileURLWithPath: source.path, isDirectory: true)
            source.bookmarkData = makeBookmark(for: kept) ?? source.bookmarkData
            source.smbURL = smb
            log.info("SMB remounted \(smb, privacy: .public); kept path \(kept.path, privacy: .public)")
            return kept
        }
        source.path = mounted.path
        source.smbURL = smb
        source.bookmarkData = makeBookmark(for: mounted) ?? source.bookmarkData
        log.info("SMB mounted \(smb, privacy: .public) → \(mounted.path, privacy: .public)")
        return mounted
    }

    /// Mount an SMB share using OS NetFS first (silent NoUI), then AllowUI / system Connect UI as needed.
    /// - Parameter allowSystemUI: When true, fall back to NetFS AllowUI and `NSWorkspace.open(smb://…)` with polling.
    static func mount(
        smbURLString: String,
        username: String?,
        password: String,
        allowSystemUI: Bool = true
    ) throws -> URL {
        let normalized = try SMBSourceURL.normalize(smbURLString)

        if let existing = findExistingMount(forSMBURL: normalized) {
            log.info("SMB already mounted \(normalized, privacy: .public) → \(existing.path, privacy: .public)")
            return existing
        }

        let user = (username?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        // 1) Silent remount with Keychain credentials (no system auth sheet).
        var lastError: Error?
        do {
            return try netFSMountReturningURL(
                normalized: normalized,
                username: user,
                password: password,
                uiOption: kNAUIOptionNoUI
            )
        } catch {
            lastError = error
            log.info("NetFS NoUI mount failed: \(error.localizedDescription, privacy: .public)")
        }

        if allowSystemUI {
            // 2) Allow macOS auth / Local Network UI.
            do {
                return try netFSMountReturningURL(
                    normalized: normalized,
                    username: user,
                    password: password,
                    uiOption: kNAUIOptionAllowUI
                )
            } catch {
                lastError = error
                log.info("NetFS AllowUI mount failed: \(error.localizedDescription, privacy: .public)")
            }

            // 3) Open smb:// via Finder/system Connect UI, then poll /Volumes (bounded timeout).
            do {
                return try openViaSystemConnectAndWait(
                    normalized: normalized,
                    username: user
                )
            } catch {
                lastError = error
                log.info("System connect poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let lastError {
            throw lastError
        }
        throw MountError.mountFailed("Unknown SMB mount failure.")
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Fail-closed probe used during Sync (start + mid-run).
    static func assertSourceReachable(path: String, isSMB: Bool) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard isReachableDirectory(url) else {
            if isSMB || path.hasPrefix("/Volumes/") {
                throw MountError.volumeLost(path)
            }
            throw MountError.volumeUnavailable(path)
        }
        if isSMB || looksLikeNetworkVolume(url) {
            // Touch volume metadata — if the share dropped, this fails even if the path string lingers briefly.
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsLocalKey, .volumeUUIDStringKey]
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.volumeName == nil && values.volumeUUIDString == nil {
                    throw MountError.volumeLost(path)
                }
            } catch let err as MountError {
                throw err
            } catch {
                throw MountError.volumeLost("\(path) (\(error.localizedDescription))")
            }
        }
    }

    static func looksLikeNetworkVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        if values?.volumeIsLocal == false { return true }
        // SMB mounts land under /Volumes (alongside removable disks); treat as network-ish for fail-closed.
        return url.path.hasPrefix("/Volumes/")
    }

    static func savePassword(_ password: String, for source: BackupSource) throws {
        try CredentialStore.saveSharedOrLocal(password, account: source.smbPasswordKeychainAccount)
    }

    static func deletePassword(for source: BackupSource) {
        CredentialStore.delete(account: source.smbPasswordKeychainAccount, useAccessGroup: true)
        CredentialStore.delete(account: source.smbPasswordKeychainAccount, useAccessGroup: false)
    }

    static func loadPassword(for source: BackupSource) throws -> String {
        do {
            return try CredentialStore.readSharedOrLocal(account: source.smbPasswordKeychainAccount)
        } catch {
            throw MountError.missingCredentials
        }
    }

    /// Present an in-app folder picker rooted at the mounted volume. Returns nil if the user cancels (caller may use share root).
    static func pickFolderUnderMountedShare(
        startingAt mounted: URL,
        message: String = "Choose the share root or a subfolder to sync."
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = mounted
        panel.message = message
        panel.prompt = "Use this folder"
        panel.title = "SMB folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Soft-guard: prefer paths under the mounted volume (user can navigate elsewhere; we still accept).
        return url
    }

    // MARK: - Internals

    private static func normalizedSMBURL(from source: BackupSource) throws -> String {
        if let smb = source.smbURL, !smb.isEmpty {
            return try SMBSourceURL.normalize(smb)
        }
        throw MountError.invalidURL("SMB source is missing smb:// URL.")
    }

    private static func tryResolveExisting(source: BackupSource) -> URL? {
        if let data = source.bookmarkData, let url = resolveBookmark(data), isReachableDirectory(url) {
            return url
        }
        let pathURL = URL(fileURLWithPath: source.path, isDirectory: true)
        if isReachableDirectory(pathURL) {
            return pathURL
        }
        if let smb = source.smbURL, let existing = try? findExistingMount(forSMBURL: SMBSourceURL.normalize(smb)) {
            return existing
        }
        return nil
    }

    private static func isReachableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return true
    }

    /// Best-effort match of an already-mounted share under `/Volumes`.
    static func findExistingMount(forSMBURL smb: String) -> URL? {
        let share = SMBSourceURL.shareName(from: smb)?.lowercased()
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: [.isDirectoryKey, .volumeIsLocalKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for item in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let share {
                let leaf = item.lastPathComponent.lowercased()
                if leaf == share || leaf.hasPrefix(share + "-") {
                    return item
                }
            }
        }
        return nil
    }

    /// NetFS mount that returns the mount URL on success.
    private static func netFSMountReturningURL(
        normalized: String,
        username: String?,
        password: String,
        uiOption: String
    ) throws -> URL {
        guard let cfURL = CFURLCreateWithString(nil, normalized as CFString, nil) else {
            throw MountError.invalidURL("Invalid SMB URL after normalize.")
        }

        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = uiOption

        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountAtMountDirKey] = kCFBooleanTrue

        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            cfURL,
            nil,
            username as CFString?,
            password as CFString,
            openOptions,
            mountOptions,
            &mountpoints
        )

        if status == 0 {
            if let array = mountpoints?.takeRetainedValue() as? [String],
               let first = array.first,
               !first.isEmpty {
                return URL(fileURLWithPath: first, isDirectory: true)
            }
            if let existing = findExistingMount(forSMBURL: normalized) {
                return existing
            }
            throw MountError.mountFailed("NetFS returned no mount point.")
        }

        // Already mounted can surface as non-zero with the volume present.
        if let existing = findExistingMount(forSMBURL: normalized) {
            return existing
        }

        throw MountError.mountFailed(netFSStatusDescription(status))
    }



    /// Open `smb://[user@]host/share…` so macOS shows Connect to Server UI, then poll `/Volumes`.
    private static func openViaSystemConnectAndWait(normalized: String, username: String?) throws -> URL {
        if let existing = findExistingMount(forSMBURL: normalized) {
            return existing
        }

        let openURL = connectURL(normalized: normalized, username: username)
        log.info("Opening system SMB connect UI for \(openURL.absoluteString, privacy: .public)")
        let opened = NSWorkspace.shared.open(openURL)
        if !opened {
            throw MountError.mountFailed(
                "Could not open \(openURL.absoluteString). Check Local Network privacy for CryptoMako, or use Finder → Go → Connect to Server."
            )
        }

        let deadline = Date().addingTimeInterval(systemConnectPollTimeout)
        while Date() < deadline {
            if let existing = findExistingMount(forSMBURL: normalized) {
                log.info("System connect mounted \(normalized, privacy: .public) → \(existing.path, privacy: .public)")
                return existing
            }
            Thread.sleep(forTimeInterval: systemConnectPollInterval)
        }

        throw MountError.mountTimedOut(normalized)
    }

    /// Build an `smb://` URL suitable for `NSWorkspace.open` (username optional; never embed password).
    static func connectURL(normalized: String, username: String?) -> URL {
        SMBSourceURL.connectURL(normalized: normalized, username: username)
    }

    private static func netFSStatusDescription(_ status: Int32) -> String {
        // Common NetFS / errno-ish codes.
        switch status {
        case Int32(EPERM):
            return "Operation not permitted (EPERM / status \(status)). Grant CryptoMako Local Network access in System Settings → Privacy & Security, and complete the system Connect to Server prompt if it appears (or mount once in Finder)."
        case Int32(EAUTH), -1:
            return "authentication failed (status \(status))"
        case Int32(ENOENT):
            return "share not found (status \(status))"
        case Int32(ENOTSUP):
            return "SMB mount not supported (status \(status))"
        case Int32(ETIMEDOUT):
            return "timed out contacting server (status \(status))"
        default:
            let msg = String(cString: strerror(status))
            var text = "status \(status): \(msg)"
            if status == 1 {
                // errno 1 is EPERM on Darwin — NetFS often returns raw 1.
                text += ". If this is EPERM: check Local Network privacy for CryptoMako; the system Connect UI may appear on retry."
            }
            return text
        }
    }
}
