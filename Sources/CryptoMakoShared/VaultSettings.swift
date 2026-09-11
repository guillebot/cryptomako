import Foundation

/// Non-secret connection settings.
///
/// Written twice on purpose: the app-group container is the only place a
/// sandboxed File Provider extension can read, while `~/.config/cryptomako/poc.json`
/// keeps the CLI working with the same values.
public struct VaultSettings: Codable, Sendable, Equatable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String
    /// Absolute path to a format-8 vault on disk. When set, S3 fields are unused.
    public var localVaultPath: String
    public init(
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String = "",
        prefix: String = "",
        accessKey: String = "",
        localVaultPath: String = ""
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.localVaultPath = localVaultPath
    }

    public var isLocal: Bool {
        !localVaultPath.isEmpty
    }

    public var isComplete: Bool {
        if isLocal {
            return true
        }
        return !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty && URL(string: endpoint) != nil
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, region, bucket, prefix, accessKey, localVaultPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        accessKey = try container.decodeIfPresent(String.self, forKey: .accessKey) ?? ""
        localVaultPath = try container.decodeIfPresent(String.self, forKey: .localVaultPath) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(region, forKey: .region)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(accessKey, forKey: .accessKey)
        if !localVaultPath.isEmpty {
            try container.encode(localVaultPath, forKey: .localVaultPath)
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        for url in [Self.appGroupConfigURL, Self.cliConfigURL].compactMap({ $0 }) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}
