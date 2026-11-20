import CryptoMakoShared
import CryptoMakoVault
import FileProvider
import Foundation

/// One item fileproviderd currently stores on disk, as the system sees it.
struct MaterializedEntry: Sendable {
    let identifier: NSFileProviderItemIdentifier
    let parent: NSFileProviderItemIdentifier
    let filename: String
    let kind: WorkingSetRefresh.ItemKind
    /// Directory the item lives in (vault dirId); nil for the root.
    let parentDirId: String?
    /// cipherName for files, dirId for directories.
    let ownKey: String
    let documentSize: Int64?
    let contentVersion: Data?
}

/// Materialized items grouped by the vault directory that lists them, so the
/// refresh does one S3 listing per directory instead of one per file.
struct RefreshSnapshot: Sendable {
    struct Group: Sendable {
        let parentDirId: String
        let entries: [MaterializedEntry]
    }

    var root: MaterializedEntry?
    var groups: [Group]

    init(entries: [MaterializedEntry]) {
        root = entries.first { $0.kind == .root }
        var byParent: [String: [MaterializedEntry]] = [:]
        for e in entries where e.kind != .root {
            guard let p = e.parentDirId else { continue }
            byParent[p, default: []].append(e)
        }
        groups = byParent.keys.sorted().map { Group(parentDirId: $0, entries: byParent[$0] ?? []) }
    }

    var itemCount: Int { groups.reduce(root == nil ? 0 : 1) { $0 + $1.entries.count } }
}

/// Collects materialized items (outside `enumerateChanges`, so we never call back
/// into fileproviderd while it waits on us) and signals the working set when ready.
actor CapabilityRefresher {
    private let domain: NSFileProviderDomain
    private(set) var snapshot: RefreshSnapshot?
    /// `requestedGeneration` when the current snapshot was collected.
    private(set) var snapshotGeneration = 0
    /// True once a partial anchor was handed out for the current snapshot.
    private(set) var servedPartial = false
    private var anyGroupFailed = false
    private var collecting = false
    private var lastFailureAt: Date?

    /// Wait before retrying after a failed collection / pass.
    static let retryBackoff: TimeInterval = 300
    /// Give up on a materialized-items enumeration that never calls back.
    static let collectTimeout: TimeInterval = 180

    init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    func markServedPartial() { servedPartial = true }
    func markGroupFailed() { anyGroupFailed = true }

    /// Drops the snapshot after a full pass. Returns whether any group failed.
    func finishPass() -> Bool {
        let failed = anyGroupFailed
        snapshot = nil
        servedPartial = false
        anyGroupFailed = false
        if failed { lastFailureAt = Date() }
        return failed
    }

    /// Starts a background collection unless one is running, ready, or backing off.
    func startCollecting(generation: Int) {
        guard !collecting, snapshot == nil else { return }
        if let last = lastFailureAt, Date().timeIntervalSince(last) < Self.retryBackoff {
            log.notice("capability refresh: backing off after a failure (retry in \(Int(Self.retryBackoff - Date().timeIntervalSince(last)), privacy: .public)s)")
            return
        }
        collecting = true
        let domain = self.domain
        log.notice("capability refresh: collecting materialized items (generation \(generation, privacy: .public))")
        Task.detached {
            do {
                let started = Date()
                let entries = try await withTimeout(seconds: Self.collectTimeout) {
                    try await Self.collect(domain: domain)
                }
                let snap = RefreshSnapshot(entries: entries)
                await self.finishCollecting(snap, generation: generation, failed: false)
                log.notice("capability refresh: collected \(entries.count, privacy: .public) item(s) needing update in \(snap.groups.count, privacy: .public) folder(s) (\(Int(Date().timeIntervalSince(started)), privacy: .public)s); signalling working set")
                do {
                    try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
                } catch {
                    log.error("capability refresh: signalEnumerator failed: \(String(describing: error), privacy: .public)")
                }
            } catch {
                log.error("capability refresh: materialized enumeration failed: \(String(describing: error), privacy: .public)")
                await self.finishCollecting(nil, generation: generation, failed: true)
                CapabilityRefreshState.update { $0.lastStatus = "collect failed: \(error.localizedDescription)"; $0.lastStatusAt = Date() }
            }
        }
    }

    private func finishCollecting(_ snap: RefreshSnapshot?, generation: Int, failed: Bool) {
        collecting = false
        snapshot = snap
        snapshotGeneration = generation
        servedPartial = false
        anyGroupFailed = false
        if failed { lastFailureAt = Date() }
    }

    private static func collect(domain: NSFileProviderDomain) async throws -> [MaterializedEntry] {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var entries: [MaterializedEntry] = []
        var seen = 0
        var pages = 0
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        while true {
            let (items, next) = try await PageCollector.page(of: enumerator, startingAt: page)
            pages += 1
            seen += items.count
            for item in items {
                if let e = entry(for: item) { entries.append(e) }
            }
            if pages % 20 == 0 {
                log.notice("capability refresh: materialized pages=\(pages, privacy: .public) seen=\(seen, privacy: .public) candidates=\(entries.count, privacy: .public)")
            }
            guard let next else { break }
            page = next
        }
        log.notice("capability refresh: materialized enumeration done pages=\(pages, privacy: .public) seen=\(seen, privacy: .public) candidates=\(entries.count, privacy: .public)")
        return entries
    }

    /// Maps a system item to a refresh entry, or nil when it must be left alone.
    static func entry(for item: NSFileProviderItem) -> MaterializedEntry? {
        let id = item.itemIdentifier
        if id == .trashContainer || id == .workingSet { return nil }
        let kind: WorkingSetRefresh.ItemKind
        let parentDirId: String?
        let ownKey: String
        switch ItemID.parse(id) {
        case .root?:
            kind = .root
            parentDirId = nil
            ownKey = ""
        case .directory(let dirId, let parent?)?:
            kind = .directory
            parentDirId = parent
            ownKey = dirId
        case .file(let parent, let cipherName)?:
            kind = .file
            parentDirId = parent
            ownKey = cipherName
        default:
            // Legacy / temporary identifiers: never invent an update for them.
            return nil
        }
        let version = item.itemVersion
        let size: NSNumber? = item.documentSize ?? nil
        guard WorkingSetRefresh.needsRefresh(
            kind: kind,
            isDownloaded: kind == .file ? item.isDownloaded : nil,
            isUploaded: item.isUploaded,
            isUploading: item.isUploading,
            hasUnresolvedConflicts: nil, // not exposed on macOS items; fileproviderd refuses evicting conflicts anyway
            capabilities: item.capabilities,
            metadataVersion: version?.metadataVersion,
            contentVersion: version?.contentVersion
        ) else { return nil }
        return MaterializedEntry(
            identifier: id,
            parent: item.parentItemIdentifier,
            filename: item.filename,
            kind: kind,
            parentDirId: parentDirId,
            ownKey: ownKey,
            documentSize: size?.int64Value,
            contentVersion: version?.contentVersion
        )
    }
}

/// Bridges one page of an `NSFileProviderEnumerator` to async/await.
private final class PageCollector: NSObject, NSFileProviderEnumerationObserver {
    private var items: [NSFileProviderItem] = []
    private var continuation: CheckedContinuation<([NSFileProviderItem], NSFileProviderPage?), Error>?

    static func page(
        of enumerator: NSFileProviderEnumerator,
        startingAt page: NSFileProviderPage
    ) async throws -> ([NSFileProviderItem], NSFileProviderPage?) {
        let collector = PageCollector()
        return try await withCheckedThrowingContinuation { cont in
            collector.continuation = cont
            enumerator.enumerateItems(for: collector, startingAt: page)
        }
    }

    func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
        items.append(contentsOf: updatedItems)
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        continuation?.resume(returning: (items, nextPage))
        continuation = nil
    }

    func finishEnumeratingWithError(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Working set: empty for `enumerateItems`, but its change enumeration carries the
/// one-time capability refresh (see `WorkingSetRefresh`). Metadata-only: an item is
/// reported only when remote truth has the same identifier, parent, name and
/// content version the system already has, so nothing re-downloads, nothing is
/// renamed or moved, and local unuploaded edits are untouched. No deletions are
/// ever reported from here.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let refresher: CapabilityRefresher
    private let index: VaultIndex
    private let domainDisplayName: String
    private var task: Task<Void, Never>?

    init(refresher: CapabilityRefresher, index: VaultIndex, domainDisplayName: String) {
        self.refresher = refresher
        self.index = index
        self.domainDisplayName = domainDisplayName
    }

    func invalidate() {
        task?.cancel()
        task = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let st = CapabilityRefreshState.load()
        completionHandler(NSFileProviderSyncAnchor(st.completedAnchor(revision: FileProviderCapabilitySets.metadataRevision)))
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let revision = FileProviderCapabilitySets.metadataRevision
        let st = CapabilityRefreshState.load()
        // Decide from the shared state, not the anchor: fileproviderd can adopt a new
        // anchor via currentSyncAnchor without ever asking for changes (1.0.18 bug).
        guard st.needsRefresh(revision: revision) else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        let anchorState = WorkingSetRefresh.state(of: anchor.rawValue)
        task = Task { [refresher, index, domainDisplayName] in
            guard let snapshot = await refresher.snapshot else {
                log.notice("capability refresh: needed (revision \(revision, privacy: .public), done=\(st.completedRevision ?? "none", privacy: .public) gen \(st.completedGeneration, privacy: .public)/\(st.requestedGeneration, privacy: .public)); starting collection")
                // Collect first (async, outside this call); it signals when ready.
                await refresher.startCollecting(generation: st.requestedGeneration)
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            var start = 0
            if case .partial(let next) = anchorState, await refresher.servedPartial {
                start = next
            }
            let session: VaultSession
            do {
                session = try await index.session()
            } catch {
                log.error("capability refresh: vault not available in the extension (\(String(describing: error), privacy: .public)); will retry on next signal")
                CapabilityRefreshState.update { $0.lastStatus = "waiting: vault locked in Finder extension"; $0.lastStatusAt = Date() }
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            var updated: [NSFileProviderItem] = []
            if start == 0, snapshot.root != nil {
                updated.append(VaultItem.root(displayName: domainDisplayName))
            }
            let end = min(start + WorkingSetRefresh.groupsPerPage, snapshot.groups.count)
            var listFailures = 0
            if start < end {
                for group in snapshot.groups[start..<end] {
                    if Task.isCancelled { return }
                    do {
                        let nodes = try await session.list(dirId: group.parentDirId)
                        updated.append(contentsOf: Self.items(for: group, listing: nodes))
                    } catch {
                        listFailures += 1
                        await refresher.markGroupFailed()
                    }
                }
            }
            var i = 0
            while i < updated.count {
                observer.didUpdate(Array(updated[i..<min(i + 500, updated.count)]))
                i += 500
            }
            log.notice("capability refresh: folders \(start, privacy: .public)..<\(end, privacy: .public) of \(snapshot.groups.count, privacy: .public): reported \(updated.count, privacy: .public) update(s), listing failures \(listFailures, privacy: .public)")
            if end < snapshot.groups.count {
                await refresher.markServedPartial()
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(WorkingSetRefresh.partialAnchor(nextGroup: end)),
                    moreComing: true
                )
                return
            }
            let generation = await refresher.snapshotGeneration
            let failed = await refresher.finishPass()
            if failed {
                log.error("capability refresh: pass finished with listing failures; retrying later")
                CapabilityRefreshState.update { $0.lastStatus = "partial: some folders could not be listed, will retry"; $0.lastStatusAt = Date() }
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(Data("ws-retry|\(Date().timeIntervalSince1970)".utf8)),
                    moreComing: false
                )
                return
            }
            let done = CapabilityRefreshState.update {
                $0.markCompleted(revision: revision, generation: generation, status: "done: \(snapshot.itemCount) item(s) refreshed")
            }
            log.notice("capability refresh: pass complete (\(snapshot.itemCount, privacy: .public) candidate item(s), revision \(revision, privacy: .public), generation \(generation, privacy: .public))")
            observer.finishEnumeratingChanges(
                upTo: NSFileProviderSyncAnchor(done.completedAnchor(revision: revision)),
                moreComing: false
            )
        }
    }

    /// Metadata-only updates for one directory's materialized entries.
    static func items(for group: RefreshSnapshot.Group, listing nodes: [VaultNode]) -> [NSFileProviderItem] {
        var out: [NSFileProviderItem] = []
        for e in group.entries {
            switch e.kind {
            case .file:
                guard let node = nodes.first(where: { $0.kind == .file && $0.cipherName == e.ownKey }) else { continue }
                let remoteContent = Data((node.eTag ?? "0").utf8)
                guard remoteContent == e.contentVersion,
                      node.cleartextName == e.filename,
                      ItemID.node(node) == e.identifier
                else { continue }
                out.append(
                    VaultItem.file(
                        node: node,
                        parentItemIdentifier: e.parent,
                        documentSize: e.documentSize.map { NSNumber(value: $0) },
                        downloaded: true
                    )
                )
            case .directory:
                guard let node = nodes.first(where: { $0.kind == .directory && $0.dirId == e.ownKey }),
                      node.cleartextName == e.filename
                else { continue }
                let item = VaultItem.directory(
                    dirId: e.ownKey,
                    parentDirId: group.parentDirId,
                    name: node.cleartextName,
                    parentItemIdentifier: e.parent
                )
                guard item.itemIdentifier == e.identifier else { continue }
                out.append(item)
            case .root:
                continue
            }
        }
        return out
    }
}

/// Runs `operation`, throwing `RefreshTimeout`
/// if it has not finished after `seconds` (the operation keeps running detached; we
/// just stop waiting, so a callback that never fires cannot wedge the refresh).
struct RefreshTimeout: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "timed out after \(Int(seconds))s" }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = OnceFlag()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        Task.detached {
            do {
                let v = try await operation()
                if once.claim() { cont.resume(returning: v) }
            } catch {
                if once.claim() { cont.resume(throwing: error) }
            }
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { cont.resume(throwing: RefreshTimeout(seconds: seconds)) }
        }
    }
}
