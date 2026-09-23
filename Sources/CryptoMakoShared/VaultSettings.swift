import Foundation

/// Non-secret connection settings.
///
/// Written twice on purpose: the app-group container is the only place a
/// sandboxed File Provider extension can read, while `~/.config/cryptomako/poc.json`
/// keeps the CLI working with the same values.
public struct VaultSettings: Codable, Sendable, Equatable {
    public enum StorageMode: String, Codable, Sendable, Equatable, CaseIterable, Hashable {
        case local
        case s3
    }

    public var storageMode: StorageMode
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// Folder inside the bucket that contains `vault.cryptomator` (trailing `/` preferred).
    public var prefix: String
    public var accessKey: String
    /// Absolute path to a format-8 vault on disk. Used when `storageMode == .local`.
    public var localVaultPath: String
    /// When true, unlock on launch and reconnect after S3 endpoint comes back.
    public var autoReconnect: Bool

    public init(
        storageMode: StorageMode = .s3,
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String = "",
        prefix: String = "",
        accessKey: String = "",
        localVaultPath: String = "",
        autoReconnect: Bool = false
    ) {
        self.storageMode = storageMode
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.localVaultPath = localVaultPath
        self.autoReconnect = autoReconnect
    }

    public var isLocal: Bool {
        storageMode == .local
    }

    public var isComplete: Bool {
        if isLocal {
            return !localVaultPath.isEmpty
        }
        return !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty && URL(string: endpoint) != nil
    }

    /// Prefix used for object keys: empty (bucket root) or guaranteed trailing `/`.
    public var normalizedPrefix: String {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    /// Human-readable object the unlock path will fetch.
    public var vaultObjectKeyPreview: String {
        let b = bucket.isEmpty ? "<bucket>" : bucket
        return "\(b)/\(normalizedPrefix)vault.cryptomator"
    }

    /// Mutating normalize for save/unlock.
    public mutating func normalizeForSave() {
        prefix = normalizedPrefix
        if storageMode == .s3 {
            // Keep local path for convenience when switching back, but do not treat as local.
        }
    }

    enum CodingKeys: String, CodingKey {
        case storageMode, endpoint, region, bucket, prefix, accessKey, localVaultPath, autoReconnect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey) ?? ""
        localVaultPath = try container.decodeIfPresent(String.self, forKey: .localVaultPath) ?? ""
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
        if let mode = try container.decodeIfPresent(StorageMode.self, forKey: .storageMode) {
            storageMode = mode
        } else {
            // Legacy configs: non-empty local path meant local vault.
            storageMode = localVaultPath.isEmpty ? .s3 : .local
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageMode, forKey: .storageMode)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(region, forKey: .region)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(normalizedPrefix, forKey: .prefix)
        try container.encode(accessKey, forKey: .accessKey)
        if !localVaultPath.isEmpty {
            try container.encode(localVaultPath, forKey: .localVaultPath)
        }
        try container.encode(autoReconnect, forKey: .autoReconnect)
    }

    // MARK: - Locations

    public static var cliConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cryptomako/poc.json")
    }

    public static var appGroupConfigURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("settings.json")
    }

    // MARK: - IO

    /// Prefers the app-group copy (the extension has nothing else), falls back to the CLI path.
    public static func load() -> VaultSettings? {
        for url in [appGroupConfigURL, cliConfigURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let settings = try? JSONDecoder().decode(VaultSettings.self, from: data)
            {
                return settings
            }
        }
        return nil
    }

    public func save() throws {
        var copy = self
        copy.normalizeForSave()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        for url in [Self.appGroupConfigURL, Self.cliConfigURL].compactMap({ $0 }) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}
