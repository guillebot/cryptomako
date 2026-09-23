import Foundation

/// Filesystem-backed `ObjectStore`. Used for `cryptomako --local`, unit tests,
/// and explicit Local mode only. Product File Provider mounts are remote-only (S3).
public final class DirectoryObjectStore: ObjectStore, @unchecked Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func getObject(key: String) async throws -> Data {
        let url = try SafePath.resolve(root: root, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ObjectStoreError.notFound(key)
        }
        return try Data(contentsOf: url)
    }

    public func getObject(key: String, to fileURL: URL) async throws {
        let source = try SafePath.resolve(root: root, key: key)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ObjectStoreError.notFound(key)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.copyItem(at: source, to: fileURL)
    }

    public func headObject(key: String) async throws -> ListedObject {
        let url = try SafePath.resolve(root: root, key: key)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ObjectStoreError.notFound(key)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return ListedObject(key: key, size: Int64(values.fileSize ?? 0), eTag: "local")
    }

    public func listImmediate(prefix: String) async throws -> PrefixListing {
        let dir = try SafePath.resolve(root: root, key: prefix)
        var objects: [ListedObject] = []
        var prefixes: [String] = []
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )) ?? []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                prefixes.append(prefix + item.lastPathComponent + "/")
            } else {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                objects.append(ListedObject(key: prefix + item.lastPathComponent, size: size, eTag: "local"))
            }
        }
        return PrefixListing(objects: objects, commonPrefixes: prefixes)
    }

    public func putObject(key: String, data: Data) async throws {
        let url = try SafePath.resolve(root: root, key: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func deleteObject(key: String) async throws {
        let url = try SafePath.resolve(root: root, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ObjectStoreError.notFound(key)
        }
        try FileManager.default.removeItem(at: url)
    }
}
