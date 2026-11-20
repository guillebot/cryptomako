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

    public init(
        requestedGeneration: Int = 0,
        completedRevision: String? = nil,
        completedGeneration: Int = 0,
        lastStatus: String? = nil,
        lastStatusAt: Date? = nil
    ) {
        self.requestedGeneration = requestedGeneration
        self.completedRevision = completedRevision
        self.completedGeneration = completedGeneration
        self.lastStatus = lastStatus
        self.lastStatusAt = lastStatusAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedGeneration = try c.decodeIfPresent(Int.self, forKey: .requestedGeneration) ?? 0
        completedRevision = try c.decodeIfPresent(String.self, forKey: .completedRevision)
        completedGeneration = try c.decodeIfPresent(Int.self, forKey: .completedGeneration) ?? 0
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastStatusAt = try c.decodeIfPresent(Date.self, forKey: .lastStatusAt)
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
            .appendingPathComponent("capability-refresh.json")
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
