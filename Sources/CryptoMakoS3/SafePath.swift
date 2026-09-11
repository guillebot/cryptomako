import Foundation

enum SafePath {
    /// Maps an object key under `root`, rejecting `..` and absolute escape.
    static func resolve(root: URL, key: String) throws -> URL {
        if key.isEmpty {
            return root
        }
        if key.contains("..") || key.hasPrefix("/") {
            throw ObjectStoreError.transport("invalid object key")
        }
        let candidate = root.appendingPathComponent(key)
        let rootPath = root.standardizedFileURL.path
        let resolvedPath = candidate.standardizedFileURL.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw ObjectStoreError.transport("invalid object key")
        }
        return candidate
    }
}
