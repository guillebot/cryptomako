import Foundation

/// Coalesces concurrent vault-directory resolution by cleartext relative path.
///
/// The shared work is detached from any one waiter so cancelling one upload does
/// not cancel directory creation for other uploads waiting on the same folder.
public actor BackupDirectoryResolutionCache {
    public typealias Lookup = @Sendable (_ parentID: String, _ name: String) async throws -> String?
    public typealias Create = @Sendable (_ parentID: String, _ name: String) async throws -> String

    private struct InFlight {
        let id: UUID
        let task: Task<String, Error>
    }

    private let rootDirectoryID: String
    private let lookup: Lookup
    private let create: Create
    private var directoryIDs: [String: String]
    private var inFlight: [String: InFlight] = [:]

    public init(rootDirectoryID: String, lookup: @escaping Lookup, create: @escaping Create) {
        self.rootDirectoryID = rootDirectoryID
        self.lookup = lookup
        self.create = create
        self.directoryIDs = ["": rootDirectoryID]
    }

    public func resolve(_ relativeFolder: String) async throws -> String {
        try Task.checkCancellation()
        let key = relativeFolder == "." ? "" : relativeFolder
        if let hit = directoryIDs[key] { return hit }
        if key.isEmpty { return rootDirectoryID }

        var parentID = rootDirectoryID
        var built = ""
        for part in key.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            built = built.isEmpty ? part : built + "/" + part
            if let hit = directoryIDs[built] {
                parentID = hit
                continue
            }

            let shared: InFlight
            if let existing = inFlight[built] {
                shared = existing
            } else {
                let id = UUID()
                let lookup = self.lookup
                let create = self.create
                let capturedParentID = parentID
                let capturedPart = part
                let task = Task.detached {
                    if let existing = try await lookup(capturedParentID, capturedPart) {
                        return existing
                    }
                    return try await create(capturedParentID, capturedPart)
                }
                shared = InFlight(id: id, task: task)
                inFlight[built] = shared
            }

            do {
                let directoryID = try await shared.task.value
                directoryIDs[built] = directoryID
                if inFlight[built]?.id == shared.id {
                    inFlight.removeValue(forKey: built)
                }
                parentID = directoryID
                try Task.checkCancellation()
            } catch {
                if inFlight[built]?.id == shared.id {
                    inFlight.removeValue(forKey: built)
                }
                throw error
            }
        }
        return parentID
    }
}
