import Foundation

/// Default path filters for Backup Sync. Tiny dependency-tree junk (especially
/// `node_modules`) dominates put count, starves the uplink with RTT-bound ~5 KB
/// objects, and is rarely useful to restore. Defaults are ON; a later settings
/// UI can expose overrides via `BackupSyncExcludesStore`.
public struct BackupSyncExcludes: Codable, Equatable, Sendable {
    /// Directory basenames skipped entirely (enumerator `skipDescendants`).
    public var directoryNames: Set<String>
    /// Exact file basenames skipped.
    public var fileNames: Set<String>
    /// File extensions skipped (lowercase, without dot), e.g. `"pyc"`.
    public var fileExtensions: Set<String>

    public init(
        directoryNames: Set<String> = Self.defaultDirectoryNames,
        fileNames: Set<String> = Self.defaultFileNames,
        fileExtensions: Set<String> = Self.defaultFileExtensions
    ) {
        self.directoryNames = directoryNames
        self.fileNames = fileNames
        self.fileExtensions = fileExtensions
    }

    public static let `default` = BackupSyncExcludes()

    public static let defaultDirectoryNames: Set<String> = [
        "node_modules",
        ".git",
        "__pycache__",
        ".svn",
        ".hg",
        ".tox",
        ".venv",
        "venv",
        ".idea",
        ".next",
        "Pods",
    ]

    public static let defaultFileNames: Set<String> = [
        ".DS_Store",
        "Thumbs.db",
        "desktop.ini",
    ]

    public static let defaultFileExtensions: Set<String> = [
        "pyc",
        "pyo",
    ]

    /// True when this directory basename should not be descended into.
    public func shouldSkipDirectory(named name: String) -> Bool {
        directoryNames.contains(name)
    }

    /// True when this regular file should not be uploaded.
    public func shouldSkipFile(named name: String) -> Bool {
        if fileNames.contains(name) { return true }
        if let ext = name.split(separator: ".").last.map(String.init),
           name.contains("."),
           fileExtensions.contains(ext.lowercased())
        {
            return true
        }
        // Any path segment match (e.g. .../node_modules/pkg/index.js) — belt & suspenders
        // when the enumerator did not get a chance to skipDescendants.
        return false
    }

    /// True when any path component of `relativePath` is an excluded directory.
    public func shouldSkipRelativePath(_ relativePath: String) -> Bool {
        for part in relativePath.split(separator: "/") {
            if directoryNames.contains(String(part)) { return true }
            if shouldSkipFile(named: String(part)) { return true }
        }
        return false
    }
}

/// Optional persisted overrides (empty file → defaults). Ready for a future Settings UI.
public struct BackupSyncExcludesStore: Codable, Equatable, Sendable {
    public var excludes: BackupSyncExcludes

    public init(excludes: BackupSyncExcludes = .default) {
        self.excludes = excludes
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("backup-sync-excludes.json")
    }

    public static func load() -> BackupSyncExcludes {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(BackupSyncExcludesStore.self, from: data)
        else {
            return .default
        }
        return store.excludes
    }

    public func save() {
        guard let url = Self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort.
        }
    }
}
