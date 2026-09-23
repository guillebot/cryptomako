import Foundation

/// Maps Cryptomator dirIds back to their parent.
///
/// A dirId has no parent pointer on disk, so File Provider `item(for:)` cannot
/// fill `parentItemIdentifier` without this cache. Enumeration records the
/// mapping; a miss walks from the vault root.
public actor DirectoryIndex {
    public struct DirInfo: Sendable, Equatable {
        public var parentDirId: String
        public var name: String

        public init(parentDirId: String, name: String) {
            self.parentDirId = parentDirId
            self.name = name
        }
    }

    private let session: VaultSession
    private var parents: [String: DirInfo] = [:]

    public init(session: VaultSession) {
        self.session = session
    }

    public func children(of dirId: String) async throws -> [VaultNode] {
        let nodes = try await session.list(dirId: dirId)
        for node in nodes where node.kind == .directory {
            if let childId = node.dirId {
                parents[childId] = DirInfo(parentDirId: dirId, name: node.cleartextName)
            }
        }
        return nodes
    }

    public func directoryInfo(dirId: String, hintParent: String? = nil) async throws -> DirInfo? {
        if let known = parents[dirId] {
            return known
        }
        if let hintParent {
            // Seed from the parent embedded in the item id (no full vault walk).
            _ = try await children(of: hintParent)
            if let known = parents[dirId] {
                return known
            }
        }
        try await walkFromRoot(looking: dirId)
        return parents[dirId]
    }

    public func file(parentDirId: String, cipherName: String) async throws -> VaultNode? {
        let nodes = try await children(of: parentDirId)
        return nodes.first { $0.cipherName == cipherName && $0.kind != .directory }
    }

    public func node(for identifier: ItemIdentifier) async throws -> VaultNode? {
        switch identifier {
        case .root:
            return nil
        case .directory(let dirId, let hintParent):
            guard let info = try await directoryInfo(dirId: dirId, hintParent: hintParent) else { return nil }
            return VaultNode(
                cleartextName: info.name,
                kind: .directory,
                cipherName: "",
                parentDirId: info.parentDirId,
                dirId: dirId,
                ciphertextKey: "",
                size: nil,
                eTag: nil
            )
        case .file(let parentDirId, let cipherName):
            return try await file(parentDirId: parentDirId, cipherName: cipherName)
        }
    }

    private func walkFromRoot(looking dirId: String) async throws {
        var queue = [""]
        var seen: Set<String> = [""]
        while let current = queue.first {
            queue.removeFirst()
            let nodes = try await children(of: current)
            if parents[dirId] != nil {
                return
            }
            for node in nodes where node.kind == .directory {
                if let childId = node.dirId, !seen.contains(childId) {
                    seen.insert(childId)
                    queue.append(childId)
                }
            }
        }
    }
}
