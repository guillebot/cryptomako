import Foundation

/// Default path filters for Backup Sync. Tiny dependency-tree junk (especially
/// `node_modules`) dominates put count, starves the uplink with RTT-bound ~5 KB
/// objects, and is rarely useful to restore. Defaults are ON; Settings exposes overrides via `BackupSyncExcludesStore`.
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

    /// Bump when shipping new default names so existing `backup-sync-excludes.json`
    /// snapshots opt into them once (see `BackupSyncExcludesStore.load`).
    public static let defaultsGeneration: Int = 2

    /// Names added in generation 2 (Xcode/SPM/Android build-artifact storms).
    public static let directoryNamesAddedInGeneration2: Set<String> = [
        "DerivedData",
        "DerivedData-sim",
        "Index.noindex",
        "ModuleCache.noindex",
        ".build",
        "build",
    ]

    public static let fileExtensionsAddedInGeneration2: Set<String> = [
        "swiftinterface",
    ]

    public static let defaultDirectoryNames: Set<String> = Set([
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
    ]).union(directoryNamesAddedInGeneration2)

    public static let defaultFileNames: Set<String> = [
        ".DS_Store",
        "Thumbs.db",
        "desktop.ini",
    ]

    public static let defaultFileExtensions: Set<String> = Set([
        "pyc",
        "pyo",
    ]).union(fileExtensionsAddedInGeneration2)

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
    /// Persisted generation of shipped defaults last merged into `excludes`.
    /// Missing / 0 in older files → migrate when the snapshot looks like prior defaults.
    public var defaultsGeneration: Int

    public init(excludes: BackupSyncExcludes = .default, defaultsGeneration: Int = BackupSyncExcludes.defaultsGeneration) {
        self.excludes = excludes
        self.defaultsGeneration = defaultsGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case excludes
        case defaultsGeneration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludes = try c.decode(BackupSyncExcludes.self, forKey: .excludes)
        defaultsGeneration = try c.decodeIfPresent(Int.self, forKey: .defaultsGeneration) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(excludes, forKey: .excludes)
        try c.encode(defaultsGeneration, forKey: .defaultsGeneration)
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("backup-sync-excludes.json")
    }

    public static func load() -> BackupSyncExcludes {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              var store = try? JSONDecoder().decode(BackupSyncExcludesStore.self, from: data)
        else {
            return .default
        }
        if store.migrateShippedDefaultsIfNeeded() {
            store.save()
        }
        return store.excludes
    }

    /// Apply newly shipped default names once. Pure custom snapshots (no `node_modules`)
    /// keep replace-defaults semantics; prior default snapshots gain gen-2 build excludes.
    @discardableResult
    public mutating func migrateShippedDefaultsIfNeeded() -> Bool {
        guard defaultsGeneration < BackupSyncExcludes.defaultsGeneration else { return false }
        let looksLikePriorDefaults = excludes.directoryNames.contains("node_modules")
            || defaultsGeneration >= 1
        if looksLikePriorDefaults {
            if defaultsGeneration < 2 {
                excludes.directoryNames.formUnion(BackupSyncExcludes.directoryNamesAddedInGeneration2)
                excludes.fileExtensions.formUnion(BackupSyncExcludes.fileExtensionsAddedInGeneration2)
            }
        }
        defaultsGeneration = BackupSyncExcludes.defaultsGeneration
        return true
    }

    public func save() {
        guard let url = Self.fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort.
        }
    }
}
