import Foundation

/// Local folders the user wants synced into the vault (backup sources).
public struct BackupSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    /// Cleartext folder name under `Backups/` in the vault.
    public var vaultFolderName: String
    public var addedAt: Date

    public init(id: String = UUID().uuidString, path: String, vaultFolderName: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        let name = vaultFolderName ?? URL(fileURLWithPath: path).lastPathComponent
        self.vaultFolderName = name.isEmpty ? "Backup" : name
        self.addedAt = addedAt
    }
}

public struct BackupSourcesStore: Codable, Equatable, Sendable {
    public var sources: [BackupSource]

    public init(sources: [BackupSource]) {
        self.sources = sources
    }

    public static let empty = BackupSourcesStore(sources: [])

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("backup-sources.json")
    }

    public static func load() -> BackupSourcesStore {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(BackupSourcesStore.self, from: data)
        else {
            return .empty
        }
        return store
    }

    public func save() throws {
        guard let url = Self.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
