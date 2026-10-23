import Foundation
import OSLog

/// Per-file fingerprint so Backup Sync can skip unchanged files (mtime + size).
public struct BackupFileFingerprint: Codable, Equatable, Sendable {
    public var size: Int64
    public var contentModification: TimeInterval

    public init(size: Int64, contentModification: Date) {
        self.size = size
        self.contentModification = contentModification.timeIntervalSinceReferenceDate
    }

    public func matches(size: Int64, contentModification: Date) -> Bool {
        self.size == size
            && abs(self.contentModification - contentModification.timeIntervalSinceReferenceDate) < 0.001
    }
}

/// Local index of successfully synced (or trusted-already-remote) backup files.
public struct BackupSyncState: Codable, Equatable, Sendable {
    private static let log = Logger(subsystem: "net.gschimmel.cryptomako", category: "backup-state")

    /// Key: "\(vaultFolderName)/\(relativePath)"
    public var files: [String: BackupFileFingerprint]

    public init(files: [String: BackupFileFingerprint] = [:]) {
        self.files = files
    }

    public static let empty = BackupSyncState()

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("backup-sync-state.json")
    }

    public static func load() throws -> BackupSyncState {
        guard let url = fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    public static func load(from url: URL) throws -> BackupSyncState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(BackupSyncState.self, from: data)
        } catch {
            log.error(
                "backup index load failed path=\(url.path, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
    }

    public func save() throws {
        guard let url = Self.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try save(to: url)
    }

    public func save(to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error(
                "backup index save failed path=\(url.path, privacy: .private(mask: .hash)) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            throw error
        }
    }

    public static func key(vaultFolder: String, relativePath: String) -> String {
        "\(vaultFolder)/\(relativePath)"
    }
}
