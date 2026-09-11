import Foundation

/// S3-backed blob store used by the vault layer.
public protocol ObjectStore: Sendable {
    func getObject(key: String) async throws -> Data
    func getObject(key: String, to fileURL: URL) async throws
    func headObject(key: String) async throws -> ListedObject
    func listImmediate(prefix: String) async throws -> PrefixListing
}

extension ObjectStore {
    /// Default HEAD: download the object. Real S3 stores override this.
    public func headObject(key: String) async throws -> ListedObject {
        let data = try await getObject(key: key)
        return ListedObject(key: key, size: Int64(data.count), eTag: nil)
    }
}

public struct PrefixListing: Sendable {
    public var objects: [ListedObject]
    public var commonPrefixes: [String]

    public init(objects: [ListedObject] = [], commonPrefixes: [String] = []) {
        self.objects = objects
        self.commonPrefixes = commonPrefixes
    }
}

public struct ListedObject: Sendable {
    public var key: String
    public var size: Int64
    public var eTag: String?

    public init(key: String, size: Int64, eTag: String? = nil) {
        self.key = key
        self.size = size
        self.eTag = eTag
    }
}

public enum ObjectStoreError: Error, LocalizedError {
    case notFound(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let key):
            return "object not found: \(key)"
        case .transport(let message):
            return message
        }
    }
}
