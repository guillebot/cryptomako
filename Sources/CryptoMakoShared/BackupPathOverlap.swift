import Foundation

/// Nested / overlapping Backup Sync sources (Platforms consensus with Windows):
/// soft-warn on add; hard-fail on Sync start when one resolved path prefixes another.
public enum BackupPathOverlap {
    public struct OverlapPair: Equatable, Sendable {
        public let a: BackupSource
        public let b: BackupSource
        public let resolvedA: String
        public let resolvedB: String

        public init(a: BackupSource, b: BackupSource, resolvedA: String, resolvedB: String) {
            self.a = a
            self.b = b
            self.resolvedA = resolvedA
            self.resolvedB = resolvedB
        }
    }

    public enum OverlapError: Error, LocalizedError, Equatable {
        case overlapping(resolvedA: String, resolvedB: String)

        public var errorDescription: String? {
            switch self {
            case .overlapping(let a, let b):
                return "Backup Sync refused: nested/overlapping sources. '\(a)' overlaps '\(b)'. Remove or change one source before syncing."
            }
        }
    }

    /// Resolve to a comparable absolute path (standardized + final symlink target when available).
    public static func resolve(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        var url = URL(fileURLWithPath: trimmed, isDirectory: true)
        // Prefer absolute + symlink-resolved form (matches Windows GetFullPath + ResolveLinkTarget spirit).
        url = url.resolvingSymlinksInPath().standardizedFileURL
        return trimTrailingSeparators(url.path)
    }

    public static func isSameOrPrefix(ancestor: String, descendant: String) -> Bool {
        let a = trimTrailingSeparators(ancestor)
        let b = trimTrailingSeparators(descendant)
        if a.caseInsensitiveCompare(b) == .orderedSame {
            return true
        }
        let prefix = a.hasSuffix("/") ? a : a + "/"
        return b.lowercased().hasPrefix(prefix.lowercased())
    }

    public static func findOverlaps(_ sources: [BackupSource]) -> [OverlapPair] {
        var resolved: [(BackupSource, String)] = []
        for source in sources {
            let path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            do {
                resolved.append((source, try resolve(path)))
            } catch {
                // Skip unresolvable for soft paths; Sync will fail separately on missing folders.
            }
        }

        var pairs: [OverlapPair] = []
        for i in 0..<resolved.count {
            for j in (i + 1)..<resolved.count {
                let (sa, pa) = resolved[i]
                let (sb, pb) = resolved[j]
                if isSameOrPrefix(ancestor: pa, descendant: pb) || isSameOrPrefix(ancestor: pb, descendant: pa) {
                    pairs.append(OverlapPair(a: sa, b: sb, resolvedA: pa, resolvedB: pb))
                }
            }
        }
        return pairs
    }

    /// Human soft-warn when adding `candidatePath` beside existing sources. Still allow the add.
    public static func softWarnOnAdd(existing: [BackupSource], candidatePath: String) -> String? {
        let candidate = BackupSource(path: candidatePath)
        let overlaps = findOverlaps(existing + [candidate])
        guard let first = overlaps.first else { return nil }
        return "Warning: backup source overlaps another (nested paths). '\(first.resolvedA)' ↔ '\(first.resolvedB)'. Sync will refuse to start until resolved."
    }

    /// Hard-fail before Sync when any pair overlaps.
    public static func throwIfOverlapping(_ sources: [BackupSource]) throws {
        guard let first = findOverlaps(sources).first else { return }
        throw OverlapError.overlapping(resolvedA: first.resolvedA, resolvedB: first.resolvedB)
    }

    private static func trimTrailingSeparators(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
