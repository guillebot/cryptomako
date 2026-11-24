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
    /// When / for which capability revision the app last wrote `AppMaterializedList`
    /// (1.0.21). A list from an older revision is rescanned.
    public var appScanAt: Date?
    public var appScanRevision: String?

    public init(
        requestedGeneration: Int = 0,
        completedRevision: String? = nil,
        completedGeneration: Int = 0,
        lastStatus: String? = nil,
        lastStatusAt: Date? = nil,
        appMaterializedCount: Int? = nil,
        appScanAt: Date? = nil,
        appScanRevision: String? = nil
    ) {
        self.requestedGeneration = requestedGeneration
        self.completedRevision = completedRevision
        self.completedGeneration = completedGeneration
        self.lastStatus = lastStatus
        self.lastStatusAt = lastStatusAt
        self.appMaterializedCount = appMaterializedCount
        self.appScanAt = appScanAt
        self.appScanRevision = appScanRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedGeneration = try c.decodeIfPresent(Int.self, forKey: .requestedGeneration) ?? 0
        completedRevision = try c.decodeIfPresent(String.self, forKey: .completedRevision)
        completedGeneration = try c.decodeIfPresent(Int.self, forKey: .completedGeneration) ?? 0
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastStatusAt = try c.decodeIfPresent(Date.self, forKey: .lastStatusAt)
        appMaterializedCount = try c.decodeIfPresent(Int.self, forKey: .appMaterializedCount)
        appScanAt = try c.decodeIfPresent(Date.self, forKey: .appScanAt)
        appScanRevision = try c.decodeIfPresent(String.self, forKey: .appScanRevision)
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

    public mutating func requestRefresh(at date: Date = Date(), status: String = "refresh requested") {
        requestedGeneration += 1
        lastStatus = status
        lastStatusAt = date
    }

    /// The app wrote a fresh `AppMaterializedList`. Bumps the generation so the
    /// extension runs a NEW pass that includes the list, even if a pass for this
    /// revision already finished (1.0.20: the pass completed 74 s before the scan
    /// landed, and the scan's signal was ignored because nothing was "needed").
    public mutating func recordAppScan(count: Int, revision: String, at date: Date = Date()) {
        appMaterializedCount = count
        appScanAt = date
        appScanRevision = revision
        requestRefresh(at: date, status: "app scan ready: \(count) downloaded item(s); refresh #\(requestedGeneration + 1) requested")
    }

    /// True when the app has no usable on-disk list for this revision.
    public func needsAppScan(revision: String) -> Bool {
        appMaterializedCount == nil || appScanRevision != revision
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

/// Counts for one refresh pass, used by the completion rule and logged verbatim.
public struct CapabilityRefreshPassStats: Equatable, Sendable {
    /// Items fileproviderd listed as materialized (before filtering).
    public var systemSeen = 0
    /// System items whose rejection reason was `.alreadyCurrent`.
    public var systemAlreadyCurrent = 0
    /// System items that are not refresh targets by nature (trash / working-set containers).
    public var systemContainers = 0
    /// Candidates handed to the vault-matching phase (system + app), root included.
    public var candidates = 0
    /// Candidates other than the root.
    public var nonRootCandidates = 0
    /// Metadata updates handed to fileproviderd, root excluded.
    public var updatedNonRoot = 0
    public var updatedRoot = false
    /// Downloaded files/folders in the app's on-disk list (nil = no list for this revision yet).
    public var appMaterialized: Int?

    public init(
        systemSeen: Int = 0, systemAlreadyCurrent: Int = 0, systemContainers: Int = 0,
        candidates: Int = 0, nonRootCandidates: Int = 0, updatedNonRoot: Int = 0,
        updatedRoot: Bool = false, appMaterialized: Int? = nil
    ) {
        self.systemSeen = systemSeen
        self.systemAlreadyCurrent = systemAlreadyCurrent
        self.systemContainers = systemContainers
        self.candidates = candidates
        self.nonRootCandidates = nonRootCandidates
        self.updatedNonRoot = updatedNonRoot
        self.updatedRoot = updatedRoot
        self.appMaterialized = appMaterialized
    }
}

public enum CapabilityRefreshOutcome: Equatable, Sendable {
    case complete(String)
    case retry(String)

    public var isComplete: Bool { if case .complete = self { return true } else { return false } }

    /// 1.0.21 rule. A pass is complete ONLY when
    /// 1. it handed at least one non-root update to fileproviderd, or
    /// 2. the downloaded set is truly empty (fileproviderd lists nothing AND the
    ///    app's on-disk scan for this revision found nothing), or
    /// 3. every item fileproviderd listed was individually verified as already
    ///    carrying `.allowsEvicting` + the current metadata (nothing lacks it), and
    ///    the app list adds nothing.
    /// Anything else (0 candidates with no explanation, candidates that matched
    /// nothing, only the root updated, no app list yet) is retried.
    ///
    /// 1.0.20 treated "system listed 77,758 items, 0 candidates" as complete; that
    /// is exactly the case rule 3 now requires a per-item explanation for.
    public static func decide(_ s: CapabilityRefreshPassStats) -> CapabilityRefreshOutcome {
        if s.updatedNonRoot > 0 {
            return .complete("updated \(s.updatedNonRoot) of \(s.nonRootCandidates) candidate item(s)")
        }
        if s.nonRootCandidates > 0 {
            return .retry("0 of \(s.nonRootCandidates) candidate item(s) could be matched on the vault")
        }
        // No candidates beyond (maybe) the root.
        guard let app = s.appMaterialized else {
            return .retry("no candidates and the app has not listed downloaded items yet")
        }
        let listed = s.systemSeen - s.systemContainers
        if listed <= 0 && app == 0 {
            return .complete("nothing is downloaded")
        }
        if listed > 0 && s.systemAlreadyCurrent == listed {
            // Any app entries were already-current system items (deduplicated away);
            // an app entry the system did not vouch for would have been a candidate.
            return .complete("all \(listed) downloaded item(s) already allow Remove Download (app list: \(app))")
        }
        return .retry("0 candidates although \(max(listed, 0)) item(s) are listed by the system (\(s.systemAlreadyCurrent) verified current) and \(app) by the app")
    }
}

/// Pure scheduling decisions shared by the extension and tests.
public enum CapabilityRefreshPlanner {
    /// A collected snapshot that predates the latest app request must be rebuilt
    /// (unless a paged pass is already being served from it).
    public static func snapshotIsStale(snapshotGeneration: Int, requestedGeneration: Int, servedPartial: Bool) -> Bool {
        !servedPartial && snapshotGeneration < requestedGeneration
    }

    /// A new generation (app scan / menu request) skips the failure backoff.
    public static func bypassBackoff(generation: Int, lastFailureGeneration: Int?) -> Bool {
        guard let last = lastFailureGeneration else { return true }
        return generation > last
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
