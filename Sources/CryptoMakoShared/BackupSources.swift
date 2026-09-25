import Foundation

/// Local folders (and optional SMB mounts) the user wants synced into the vault.
public struct BackupSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder
        case smb
    }

    public var id: String
    /// Resolved local filesystem path used by Sync (under `/Volumes/…` for SMB).
    public var path: String
    /// Cleartext folder name under `Backups/` in the vault.
    public var vaultFolderName: String
    public var addedAt: Date
    public var kind: Kind
    /// Canonical `smb://server/share[/path]` when `kind == .smb`.
    public var smbURL: String?
    /// Optional username for SMB (password lives in Keychain, never here).
    public var smbUsername: String?
    /// Security-scoped bookmark for the mounted path (remount / re-resolve).
    public var bookmarkData: Data?
    /// When this source last completed a full Sync/Backup run successfully (no cancel/fail).
    /// Nil until the first successful per-source completion. Persisted across launches.
    public var lastFullSyncAt: Date?

    public init(
        id: String = UUID().uuidString,
        path: String,
        vaultFolderName: String? = nil,
        addedAt: Date = Date(),
        kind: Kind = .folder,
        smbURL: String? = nil,
        smbUsername: String? = nil,
        bookmarkData: Data? = nil,
        lastFullSyncAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        let name = vaultFolderName
            ?? (kind == .smb ? SMBSourceURL.suggestedVaultFolderName(smbURL: smbURL, path: path) : nil)
            ?? URL(fileURLWithPath: path).lastPathComponent
        self.vaultFolderName = name.isEmpty ? "Backup" : name
        self.addedAt = addedAt
        self.kind = kind
        self.smbURL = smbURL
        self.smbUsername = smbUsername
        self.bookmarkData = bookmarkData
        self.lastFullSyncAt = lastFullSyncAt
    }

    public var isSMB: Bool { kind == .smb }

    /// Secondary line in the Backup list (path or smb:// URL).
    public var displayLocation: String {
        if kind == .smb, let smbURL, !smbURL.isEmpty {
            return smbURL
        }
        return path
    }

    /// Keychain account for this source's SMB password (host-app only).
    public var smbPasswordKeychainAccount: String {
        "smb-password-\(id)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, vaultFolderName, addedAt, kind, smbURL, smbUsername, bookmarkData, lastFullSyncAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        vaultFolderName = try c.decode(String.self, forKey: .vaultFolderName)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .folder
        smbURL = try c.decodeIfPresent(String.self, forKey: .smbURL)
        smbUsername = try c.decodeIfPresent(String.self, forKey: .smbUsername)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        lastFullSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastFullSyncAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(vaultFolderName, forKey: .vaultFolderName)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(smbURL, forKey: .smbURL)
        try c.encodeIfPresent(smbUsername, forKey: .smbUsername)
        try c.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try c.encodeIfPresent(lastFullSyncAt, forKey: .lastFullSyncAt)
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
