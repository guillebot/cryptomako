import Foundation

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

    public static func load() -> BackupSyncState {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(BackupSyncState.self, from: data)
        else {
            return .empty
        }
        return store
    }

    public func save() {
        guard let url = Self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort; never fail a sync because the index could not persist.
        }
    }

    public static func key(vaultFolder: String, relativePath: String) -> String {
        "\(vaultFolder)/\(relativePath)"
    }
}
