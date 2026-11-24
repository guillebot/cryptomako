import Foundation

/// Shared (app group) record of the File Provider capability refresh.
///
/// 1.0.18 decided "refresh needed" from the working-set sync anchor alone. On
/// Guillermo's Mac fileproviderd adopted the new anchor straight from
/// `currentSyncAnchor` (it never asked for changes from the legacy `empty` anchor),
/// so every later `enumerateChanges` arrived with the *current* anchor and the
/// refresh never ran. The decision now lives here, independent of the anchor:
/// the extension refreshes until `completedRevision` matches the current
/// capability revision and `completedGeneration` catches up with any app request
/// (Vault > Finder > Refresh Finder permissions bumps `requestedGeneration`).
public struct CapabilityRefreshState: Codable, Equatable, Sendable {
    public var requestedGeneration: Int
    public var completedRevision: String?
    public var completedGeneration: Int
    public var lastStatus: String?
    public var lastStatusAt: Date?
    /// Downloaded files + folders the app counted under the Finder location in its
    /// last scan (nil = no scan yet).
    public var appMaterializedCount: Int?

    public init(
        requestedGeneration: Int = 0,
        completedRevision: String? = nil,
        completedGeneration: Int = 0,
        lastStatus: String? = nil,
        lastStatusAt: Date? = nil,
        appMaterializedCount: Int? = nil
    ) {
        self.requestedGeneration = requestedGeneration
        self.completedRevision = completedRevision
        self.completedGeneration = completedGeneration
        self.lastStatus = lastStatus
        self.lastStatusAt = lastStatusAt
        self.appMaterializedCount = appMaterializedCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedGeneration = try c.decodeIfPresent(Int.self, forKey: .requestedGeneration) ?? 0
        completedRevision = try c.decodeIfPresent(String.self, forKey: .completedRevision)
        completedGeneration = try c.decodeIfPresent(Int.self, forKey: .completedGeneration) ?? 0
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastStatusAt = try c.decodeIfPresent(Date.self, forKey: .lastStatusAt)
        appMaterializedCount = try c.decodeIfPresent(Int.self, forKey: .appMaterializedCount)
    }

    /// True until a full pass finished for this revision and the latest app request.
    public func needsRefresh(revision: String) -> Bool {
        completedRevision != revision || completedGeneration < requestedGeneration
    }

    /// Working-set anchor once the pass for (revision, generation) is done. Changes
    /// on every completed pass so fileproviderd always sees a new anchor.
    public func completedAnchor(revision: String) -> Data {
        Data("ws|\(revision)|g\(completedGeneration)".utf8)
    }

    /// Records a finished pass that started when `requestedGeneration` was `generation`.
    public mutating func markCompleted(revision: String, generation: Int, status: String, at date: Date = Date()) {
        completedRevision = revision
        completedGeneration = max(completedGeneration, generation)
        lastStatus = status
        lastStatusAt = date
    }

    public mutating func requestRefresh(at date: Date = Date()) {
        requestedGeneration += 1
        lastStatus = "refresh requested"
        lastStatusAt = date
    }

    // MARK: - Storage (app group, shared by app and extension)

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            // v2 (1.0.20): the v1 file recorded a bogus "done: 0 item(s)" pass on
            // Guillermo's Mac; a new key forces a fresh pass for everyone.
            .appendingPathComponent("capability-refresh-v2.json")
    }

    public static func load(from url: URL? = fileURL) -> CapabilityRefreshState {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(CapabilityRefreshState.self, from: data)
        else { return CapabilityRefreshState() }
        return s
    }

    @discardableResult
    public static func update(
        at url: URL? = fileURL,
        _ mutate: (inout CapabilityRefreshState) -> Void
    ) -> CapabilityRefreshState {
        var s = load(from: url)
        mutate(&s)
        if let url, let data = try? JSONEncoder().encode(s) {
            try? data.write(to: url, options: .atomic)
        }
        return s
    }
}

// MARK: - Pass outcome (pure)

public enum CapabilityRefreshOutcome: Equatable, Sendable {
    case complete
    case retry(String)

    /// Never count a pass that changed nothing as done while downloaded items exist.
    ///
    /// - candidates: items that needed new capabilities (system + app sources).
    /// - reported: metadata updates actually handed to fileproviderd.
    /// - systemSeen: items fileproviderd listed as materialized (before filtering).
    /// - appMaterialized: downloaded files/folders the app counted on disk (nil = no scan yet).
    public static func decide(candidates: Int, reported: Int, systemSeen: Int, appMaterialized: Int?) -> CapabilityRefreshOutcome {
        if candidates > 0 && reported == 0 {
            return .retry("0 of \(candidates) candidate(s) could be matched on the vault")
        }
        if candidates == 0 && systemSeen == 0 {
            guard let app = appMaterialized else {
                return .retry("waiting for the app to count downloaded items")
            }
            if app > 0 {
                return .retry("no candidates found but the app sees \(app) downloaded item(s)")
            }
        }
        return .complete
    }
}

/// Downloaded items the app found under the Finder location (identifiers come
/// from `NSFileProviderManager.getIdentifierForUserVisibleFile`, read-only). The
/// extension merges this with the system's materialized set, so the refresh does
/// not depend on a single source.
public struct AppMaterializedList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var identifier: String
        public var parent: String
        public var filename: String
        public var isDirectory: Bool
        /// Local (cleartext) size in bytes; 0 for folders.
        public var size: Int64

        public init(identifier: String, parent: String, filename: String, isDirectory: Bool, size: Int64) {
            self.identifier = identifier
            self.parent = parent
            self.filename = filename
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public var createdAt: Date
    public var entries: [Entry]

    public init(createdAt: Date = Date(), entries: [Entry] = []) {
        self.createdAt = createdAt
        self.entries = entries
    }

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("capability-refresh-items.json")
    }

    public static func load(from url: URL? = fileURL) -> AppMaterializedList? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppMaterializedList.self, from: data)
    }

    public func save(to url: URL? = fileURL) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
