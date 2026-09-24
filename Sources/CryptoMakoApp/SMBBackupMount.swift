import CryptoMakoShared
import Foundation
import NetFS
import OSLog

/// Mount / remount SMB Backup Sync sources via macOS (`NetFS` / `/Volumes`), never an embedded SMB client.
enum SMBBackupMount {
    enum MountError: Error, LocalizedError {
        case invalidURL(String)
        case mountFailed(String)
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
        let mounted = try mount(
            smbURLString: smb,
            username: source.smbUsername,
            password: password
        )
        source.path = mounted.path
        source.smbURL = smb
        source.bookmarkData = makeBookmark(for: mounted) ?? source.bookmarkData
        log.info("SMB mounted \(smb, privacy: .public) → \(mounted.path, privacy: .public)")
        return mounted
    }

    static func mount(smbURLString: String, username: String?, password: String) throws -> URL {
        let normalized = try SMBSourceURL.normalize(smbURLString)
        guard let cfURL = CFURLCreateWithString(nil, normalized as CFString, nil) else {
            throw MountError.invalidURL("Invalid SMB URL after normalize.")
        }

        let openOptions = NSMutableDictionary()
        // Suppress system auth UI; we supply Keychain credentials ourselves.
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI

        let mountOptions = NSMutableDictionary()
        mountOptions[kNetFSMountAtMountDirKey] = kCFBooleanTrue

        var mountpoints: Unmanaged<CFArray>?
        let user = (username?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let status = NetFSMountURLSync(
            cfURL,
            nil,
            user as CFString?,
            password as CFString,
            openOptions,
            mountOptions,
            &mountpoints
        )

        if status != 0 {
            // Fallback: mount_smbfs (still OS client, not libsmbclient).
            if let fallback = try? mountViaMountSmbfs(normalized: normalized, username: user, password: password) {
                return fallback
            }
            throw MountError.mountFailed(netFSStatusDescription(status))
        }

        guard let array = mountpoints?.takeRetainedValue() as? [String],
              let first = array.first,
              !first.isEmpty
        else {
            // NetFS may succeed with an empty mountpoints array if already mounted — probe /Volumes.
            if let existing = findExistingMount(forSMBURL: normalized) {
                return existing
            }
            throw MountError.mountFailed("NetFS returned no mount point.")
        }
        return URL(fileURLWithPath: first, isDirectory: true)
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
    private static func findExistingMount(forSMBURL smb: String) -> URL? {
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

    private static func mountViaMountSmbfs(normalized: String, username: String?, password: String) throws -> URL {
        guard let url = URL(string: normalized), let host = url.host else {
            throw MountError.invalidURL(normalized)
        }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let share = parts.first else {
            throw MountError.invalidURL(normalized)
        }
        let subpath = parts.dropFirst().joined(separator: "/")
        let shareLeaf = share
        var mountDir = URL(fileURLWithPath: "/Volumes/\(shareLeaf)", isDirectory: true)
        var n = 1
        while FileManager.default.fileExists(atPath: mountDir.path) {
            mountDir = URL(fileURLWithPath: "/Volumes/\(shareLeaf)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        // mount_smbfs //user@host/share mountpoint — password via stdin env is awkward;
        // use //user:pass@host/share only in argv for the child (still OS client). Prefer NetFS.
        let user = username ?? NSUserName()
        let remote: String
        if password.isEmpty {
            remote = "//\(user)@\(host)/\(share)"
        } else {
            let encPass = password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? password
            remote = "//\(user):\(encPass)@\(host)/\(share)"
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        proc.arguments = [remote, mountDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: mountDir)
            throw MountError.mountFailed(errText.isEmpty ? "mount_smbfs exit \(proc.terminationStatus)" : errText)
        }
        if subpath.isEmpty {
            return mountDir
        }
        let nested = mountDir.appendingPathComponent(subpath, isDirectory: true)
        guard isReachableDirectory(nested) else {
            throw MountError.volumeUnavailable(nested.path)
        }
        return nested
    }

    private static func netFSStatusDescription(_ status: Int32) -> String {
        // Common NetFS / errno-ish codes.
        switch status {
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
            return "status \(status): \(msg)"
        }
    }
}
