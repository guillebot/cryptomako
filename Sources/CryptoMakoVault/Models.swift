import Foundation

public struct VaultLocation: Sendable, Equatable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var prefix: String
    public var accessKey: String

    public init(endpoint: URL, region: String, bucket: String, prefix: String, accessKey: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.prefix = Self.normalizePrefix(prefix)
    }

    public static func normalizePrefix(_ prefix: String) -> String {
        if prefix.isEmpty {
            return ""
        }
        return prefix.hasSuffix("/") ? prefix : prefix + "/"
    }

    public func key(_ relative: String) -> String {
        prefix + relative
    }
}

public struct VaultConfig: Sendable, Equatable {
    public var format: Int
    public var shorteningThreshold: Int
    public var cipherCombo: String
    public var jti: String?
    public var kid: String?

    public var schemeName: String { cipherCombo }
}

public enum NodeKind: String, Sendable {
    case file
    case directory
    case symlink
}

public struct VaultNode: Sendable {
    public var cleartextName: String
    public var kind: NodeKind
    public var cipherName: String
    public var parentDirId: String
    public var dirId: String?
    public var ciphertextKey: String
    public var size: Int64?
    public var eTag: String?

    public var itemId: String {
        switch kind {
        case .directory:
            return "d:\(dirId ?? "")"
        case .file, .symlink:
            return "f:\(parentDirId)/\(cipherName)"
        }
    }
}
