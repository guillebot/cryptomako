import Foundation

/// Relative path under a Backup source root. Fail-closed: never invent a fallback
/// leaf name when the URL is not under the root (that would corrupt Sync prune keys).
public enum BackupRelativePath {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case notUnderRoot(filePath: String, rootPath: String)

        public var errorDescription: String? {
            switch self {
            case .notUnderRoot(let filePath, let rootPath):
                return "Path is not under backup source root: \(filePath) (root \(rootPath))"
            }
        }
    }

    /// Relative path of `filePath` under `rootPath`, without allocating `URL`s.
    /// Requires a real path-component boundary (`root` or `root/…`), not a string prefix.
    public static func make(filePath: String, rootPath: String) throws -> String {
        if filePath == rootPath {
            return ""
        }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let prefix = root + "/"
        guard filePath.hasPrefix(prefix) else {
            throw Error.notUnderRoot(filePath: filePath, rootPath: rootPath)
        }
        return String(filePath.dropFirst(prefix.count))
    }
}
