import Foundation

/// Non-secret fields persisted in `~/.config/cryptomako/poc.json`.
public struct PocConfig: Codable, Sendable, Equatable {
    public var endpoint: String?
    public var region: String?
    public var bucket: String?
    public var prefix: String?
    public var accessKey: String?

    public init(
        endpoint: String? = nil,
        region: String? = nil,
        bucket: String? = nil,
        prefix: String? = nil,
        accessKey: String? = nil
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
    }
}

public enum ConnectionConfigError: Error, LocalizedError, Equatable {
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "missing \(name)"
        case .invalid(let message):
            return message
        }
    }
}

/// Resolved connection parameters for the CLI and app (secrets included).
public struct ConnectionConfig: Sendable, Equatable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String
    public var secretKey: String
    public var passphrase: String
    public var pathStyle: Bool
    public var localRoot: URL?

    public var isLocal: Bool { localRoot != nil }
}

public struct ConnectionRequest: Sendable {
    public var localPath: String?
    public var configURL: URL?
    public var endpoint: String?
    public var region: String?
    public var bucket: String?
    public var prefix: String?
    public var accessKey: String?
    public var passwordEnv: String
    public var secretKeyEnv: String
    public var virtualHosted: Bool

    public init(
        localPath: String? = nil,
        configURL: URL? = nil,
        endpoint: String? = nil,
        region: String? = nil,
        bucket: String? = nil,
        prefix: String? = nil,
        accessKey: String? = nil,
        passwordEnv: String = "CRYPTOMAKO_PASSWORD",
        secretKeyEnv: String = "CRYPTOMAKO_SECRET_KEY",
        virtualHosted: Bool = false
    ) {
        self.localPath = localPath
        self.configURL = configURL
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
        self.accessKey = accessKey
        self.passwordEnv = passwordEnv
        self.secretKeyEnv = secretKeyEnv
        self.virtualHosted = virtualHosted
    }
}

public enum ConnectionConfigLoader {
    public static func resolve(
        _ request: ConnectionRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ConnectionConfig {
        guard let passphrase = environment[request.passwordEnv], !passphrase.isEmpty else {
            throw ConnectionConfigError.missing("env \(request.passwordEnv)")
        }

        if let local = request.localPath?.trimmingCharacters(in: .whitespacesAndNewlines), !local.isEmpty {
            return ConnectionConfig(
                endpoint: URL(string: "file:///")!,
                region: "local",
                bucket: "local",
                prefix: "",
                accessKey: "local",
                secretKey: "",
                passphrase: passphrase,
                pathStyle: true,
                localRoot: URL(fileURLWithPath: local)
            )
        }

        let configURL = request.configURL ?? VaultSettings.cliConfigURL
        let file: PocConfig
        if let data = try? Data(contentsOf: configURL) {
            file = try JSONDecoder().decode(PocConfig.self, from: data)
        } else {
            file = PocConfig()
        }

        let endpointString = request.endpoint ?? file.endpoint
        let region = request.region ?? file.region ?? "us-east-1"
        let bucket = request.bucket ?? file.bucket
        let prefix = request.prefix ?? file.prefix ?? ""
        let accessKey = request.accessKey ?? file.accessKey

        guard let endpointString, let endpoint = URL(string: endpointString) else {
            throw ConnectionConfigError.missing("--endpoint")
        }
        guard let bucket, !bucket.isEmpty else {
            throw ConnectionConfigError.missing("--bucket")
        }
        guard let accessKey, !accessKey.isEmpty else {
            throw ConnectionConfigError.missing("--access-key")
        }
        guard let secretKey = environment[request.secretKeyEnv], !secretKey.isEmpty else {
            throw ConnectionConfigError.missing("env \(request.secretKeyEnv)")
        }

        return ConnectionConfig(
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            prefix: prefix,
            accessKey: accessKey,
            secretKey: secretKey,
            passphrase: passphrase,
            pathStyle: !request.virtualHosted,
            localRoot: nil
        )
    }
}
