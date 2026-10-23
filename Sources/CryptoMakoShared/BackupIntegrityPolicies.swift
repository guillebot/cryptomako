import Foundation

public enum BackupStatePersistPolicy: Sendable {
    public static let putThreshold = 512
    public static let timeThreshold: TimeInterval = 30

    /// Persist after either enough committed puts or enough elapsed time.
    public static func shouldPersist(
        putsSinceSave: Int,
        elapsed: TimeInterval,
        putThreshold: Int = putThreshold,
        timeThreshold: TimeInterval = timeThreshold
    ) -> Bool {
        putsSinceSave >= putThreshold || elapsed >= timeThreshold
    }
}

/// After upload/prune already failed, a durability `save()` may also fail.
/// Neither failure may be silently discarded.
public enum BackupPostFailureSavePolicy: Sendable {
    /// Combined primary + index-save failure for UI / tests.
    public struct DualFailure: Error, LocalizedError, Equatable, Sendable {
        public let primaryDescription: String
        public let saveDescription: String

        public init(primaryDescription: String, saveDescription: String) {
            self.primaryDescription = primaryDescription
            self.saveDescription = saveDescription
        }

        public var errorDescription: String? {
            "\(primaryDescription) Additionally, the backup index could not be saved: \(saveDescription)"
        }
    }

    /// Returns the error the Sync caller should observe.
    /// - Only primary failed → primary (unchanged).
    /// - Both failed → combined error that includes the save failure text.
    public static func errorToThrow(primary: Error, saveFailure: Error?) -> Error {
        guard let saveFailure else { return primary }
        return DualFailure(
            primaryDescription: primary.localizedDescription,
            saveDescription: saveFailure.localizedDescription
        )
    }
}

/// Precomputed local-tree membership used by Sync-mode orphan pruning.
public struct BackupPruneIndex: Sendable {
    public let localFiles: Set<String>
    public let ancestorDirectories: Set<String>

    public init(localFiles: Set<String>) {
        self.localFiles = localFiles
        var ancestors: Set<String> = [""]
        for path in localFiles {
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { continue }
            var built = ""
            for part in parts.dropLast() {
                built = built.isEmpty ? String(part) : built + "/" + part
                ancestors.insert(built)
            }
        }
        self.ancestorDirectories = ancestors
    }

    public func containsFile(_ relativePath: String) -> Bool {
        localFiles.contains(relativePath)
    }

    public func hasLocalUnder(_ relativeDirectory: String) -> Bool {
        relativeDirectory.isEmpty
            || localFiles.contains(relativeDirectory)
            || ancestorDirectories.contains(relativeDirectory)
    }

    /// A failed or incomplete scan never authorizes pruning.
    public static func shouldPrune(scanCompleted: Bool) -> Bool {
        scanCompleted
    }
}

public enum BackupPruneStateRemoval: Sendable {
    /// Computes all fingerprint removals in one pass over the state map.
    public static func keysToRemove(
        from keys: some Sequence<String>,
        vaultFolderName: String,
        deletedFiles: Set<String>,
        deletedDirectories: Set<String>
    ) -> Set<String> {
        let root = vaultFolderName + "/"
        var result = Set<String>()
        for key in keys {
            guard key.hasPrefix(root) else { continue }
            let relative = String(key.dropFirst(root.count))
            if deletedFiles.contains(relative) {
                result.insert(key)
                continue
            }
            var candidate = relative
            while !candidate.isEmpty {
                if deletedDirectories.contains(candidate) {
                    result.insert(key)
                    break
                }
                guard let slash = candidate.lastIndex(of: "/") else { break }
                candidate.removeSubrange(slash...)
            }
        }
        return result
    }
}
