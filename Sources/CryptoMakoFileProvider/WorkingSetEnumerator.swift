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
    /// True once a partial anchor was handed out for the current snapshot.
    private(set) var servedPartial = false
    private var anyGroupFailed = false
    private var collecting = false

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
        return failed
    }

    /// Starts a background collection unless one is running or ready.
    func startCollecting() {
        guard !collecting, snapshot == nil else { return }
        collecting = true
        let domain = self.domain
        Task.detached {
            do {
                let entries = try await Self.collect(domain: domain)
                await self.finishCollecting(RefreshSnapshot(entries: entries))
                log.info("capability refresh: \(entries.count) materialized item(s) need current capabilities")
                try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            } catch {
                log.error("capability refresh: materialized enumeration failed: \(error.localizedDescription, privacy: .public)")
                await self.finishCollecting(nil)
            }
        }
    }

    private func finishCollecting(_ snap: RefreshSnapshot?) {
        collecting = false
        snapshot = snap
        servedPartial = false
        anyGroupFailed = false
    }

    private static func collect(domain: NSFileProviderDomain) async throws -> [MaterializedEntry] {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var entries: [MaterializedEntry] = []
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        while true {
            let (items, next) = try await PageCollector.page(of: enumerator, startingAt: page)
            for item in items {
                if let e = entry(for: item) { entries.append(e) }
            }
            guard let next else { break }
            page = next
        }
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
        completionHandler(NSFileProviderSyncAnchor(WorkingSetRefresh.currentAnchor))
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let state = WorkingSetRefresh.state(of: anchor.rawValue)
        if state == .current {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        task = Task { [refresher, index, domainDisplayName] in
            guard let snapshot = await refresher.snapshot else {
                // Collect first (async, outside this call); it signals when ready.
                await refresher.startCollecting()
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            var start = 0
            if case .partial(let next) = state, await refresher.servedPartial {
                start = next
            }
            let session: VaultSession
            do {
                session = try await index.session()
            } catch {
                // Locked / offline: keep the old anchor and retry on the next signal.
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            var updated: [NSFileProviderItem] = []
            if start == 0, snapshot.root != nil {
                updated.append(VaultItem.root(displayName: domainDisplayName))
            }
            let end = min(start + WorkingSetRefresh.groupsPerPage, snapshot.groups.count)
            if start < end {
                for group in snapshot.groups[start..<end] {
                    if Task.isCancelled { return }
                    do {
                        let nodes = try await session.list(dirId: group.parentDirId)
                        updated.append(contentsOf: Self.items(for: group, listing: nodes))
                    } catch {
                        await refresher.markGroupFailed()
                    }
                }
            }
            var i = 0
            while i < updated.count {
                observer.didUpdate(Array(updated[i..<min(i + 500, updated.count)]))
                i += 500
            }
            if end < snapshot.groups.count {
                await refresher.markServedPartial()
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(WorkingSetRefresh.partialAnchor(nextGroup: end)),
                    moreComing: true
                )
                return
            }
            let failed = await refresher.finishPass()
            log.info("capability refresh: pass finished (\(snapshot.itemCount) candidate item(s), listing failures: \(failed, privacy: .public))")
            // On a listing failure keep a stale anchor so the next signal retries
            // (re-reporting the items that did refresh is harmless).
            let next = failed ? Data("ws-retry".utf8) : WorkingSetRefresh.currentAnchor
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(next), moreComing: false)
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
