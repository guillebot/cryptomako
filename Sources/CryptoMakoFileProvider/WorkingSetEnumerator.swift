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
    /// System content version (ETag). nil for entries from the app scan, which are
    /// matched by cleartext size instead.
    let contentVersion: Data?
}

/// Up to `perReason` example items per filter reason, without names (flags only).
struct FilterSamples: Sendable {
    static let perReason = 3
    private(set) var lines: [String] = []
    private var counts: [WorkingSetRefresh.FilterReason: Int] = [:]

    mutating func note(_ reason: WorkingSetRefresh.FilterReason, _ describe: () -> String) {
        guard reason != .candidate, counts[reason, default: 0] < Self.perReason else { return }
        counts[reason, default: 0] += 1
        lines.append("\(reason.rawValue): \(describe())")
    }
}

/// Result of one collection: deduplicated candidates plus counts for the outcome rule.
struct CollectedSet: Sendable {
    var entries: [MaterializedEntry]
    var systemSeen: Int
    var appEntries: Int
    var counters = CapabilityRefreshCounters()
    var samples = FilterSamples()
    /// nil when the app has no list for the current revision.
    var appListed: Int?
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
    var systemSeen = 0
    var appEntries = 0
    var appListed: Int?
    var counters = CapabilityRefreshCounters()

    init(entries: [MaterializedEntry]) {
        root = entries.first { $0.kind == .root }
        var byParent: [String: [MaterializedEntry]] = [:]
        for e in entries where e.kind != .root {
            guard let p = e.parentDirId else { continue }
            byParent[p, default: []].append(e)
        }
        groups = byParent.keys.sorted().map { Group(parentDirId: $0, entries: byParent[$0] ?? []) }
    }

    init(collected set: CollectedSet) {
        self.init(entries: set.entries)
        systemSeen = set.systemSeen
        appEntries = set.appEntries
        appListed = set.appListed
        counters = set.counters
    }

    var itemCount: Int { groups.reduce(root == nil ? 0 : 1) { $0 + $1.entries.count } }
    var nonRootCount: Int { groups.reduce(0) { $0 + $1.entries.count } }
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
    private(set) var matchCounters = CapabilityRefreshCounters()
    private(set) var updatedRootInPass = false
    private var collecting = false
    private var lastFailureAt: Date?
    private var lastFailureGeneration: Int?
    private var retryTask: Task<Void, Never>?

    /// Wait before retrying after a failed collection / pass.
    static let retryBackoff: TimeInterval = 300
    /// Give up on a materialized-items enumeration that never calls back.
    static let collectTimeout: TimeInterval = 180

    init(domain: NSFileProviderDomain) {
        self.domain = domain
    }

    func markServedPartial() { servedPartial = true }
    func markGroupFailed() { anyGroupFailed = true }
    func addMatch(_ c: CapabilityRefreshCounters, root: Bool) {
        for (k, v) in c.match { matchCounters.add(k, v) }
        if root { updatedRootInPass = true }
    }

    /// Pass did not complete: back off, then re-signal the working set ourselves
    /// (does not depend on the app being open).
    func noteRetry(generation: Int) {
        lastFailureAt = Date()
        lastFailureGeneration = generation
        scheduleSignal(after: Self.retryBackoff, why: "retry")
    }

    /// Re-signal soon: an app request arrived while a pass was running.
    func signalSoon(why: String) { scheduleSignal(after: 2, why: why) }

    private func scheduleSignal(after seconds: TimeInterval, why: String) {
        retryTask?.cancel()
        let domain = self.domain
        retryTask = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            log.notice("capability refresh: re-signalling working set (\(why, privacy: .public))")
            do {
                try await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
            } catch {
                log.error("capability refresh: signalEnumerator failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Drops a snapshot collected before the latest app request (not mid-pass).
    func dropIfStale(requestedGeneration: Int) -> Bool {
        guard snapshot != nil,
              CapabilityRefreshPlanner.snapshotIsStale(
                  snapshotGeneration: snapshotGeneration,
                  requestedGeneration: requestedGeneration,
                  servedPartial: servedPartial
              )
        else { return false }
        log.notice("capability refresh: snapshot from generation \(self.snapshotGeneration, privacy: .public) is older than request \(requestedGeneration, privacy: .public); recollecting")
        resetPass()
        snapshot = nil
        return true
    }

    private func resetPass() {
        servedPartial = false
        anyGroupFailed = false
        matchCounters = CapabilityRefreshCounters()
        updatedRootInPass = false
    }

    /// Drops the snapshot after a full pass. Returns whether any group failed.
    func finishPass() -> Bool {
        let failed = anyGroupFailed
        snapshot = nil
        resetPass()
        return failed
    }

    /// Starts a background collection unless one is running, ready, or backing off.
    func startCollecting(generation: Int) {
        guard !collecting, snapshot == nil else { return }
        if let last = lastFailureAt, Date().timeIntervalSince(last) < Self.retryBackoff,
           !CapabilityRefreshPlanner.bypassBackoff(generation: generation, lastFailureGeneration: lastFailureGeneration) {
            log.notice("capability refresh: backing off after a failure (retry in \(Int(Self.retryBackoff - Date().timeIntervalSince(last)), privacy: .public)s)")
            return
        }
        collecting = true
        let domain = self.domain
        log.notice("capability refresh: collecting materialized items (generation \(generation, privacy: .public))")
        Task.detached {
            do {
                let started = Date()
                let set = try await withTimeout(seconds: Self.collectTimeout) {
                    try await Self.collect(domain: domain)
                }
                let snap = RefreshSnapshot(collected: set)
                await self.finishCollecting(snap, generation: generation, failed: false)
                log.notice("capability refresh: collected \(snap.itemCount, privacy: .public) item(s) needing update in \(snap.groups.count, privacy: .public) folder(s) (\(Int(Date().timeIntervalSince(started)), privacy: .public)s); signalling working set")
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
        resetPass()
        if failed {
            lastFailureAt = Date()
            lastFailureGeneration = generation
            scheduleSignal(after: Self.retryBackoff, why: "collect failed")
        }
    }

    private static func collect(domain: NSFileProviderDomain) async throws -> CollectedSet {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSFileProviderError(.providerNotFound)
        }
        var system: [NSFileProviderItem] = []
        var pages = 0
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        // The materialized-set enumerator wants an EMPTY page (`[NSData new]`).
        var page = NSFileProviderPage(Data())
        while true {
            let (items, next) = try await PageCollector.page(of: enumerator, startingAt: page)
            pages += 1
            system.append(contentsOf: items)
            if pages % 20 == 0 {
                log.notice("capability refresh: materialized pages=\(pages, privacy: .public) seen=\(system.count, privacy: .public)")
            }
            guard let next, !next.rawValue.isEmpty, pages < 100_000 else { break }
            page = next
        }
        let st = CapabilityRefreshState.load()
        let revision = FileProviderCapabilitySets.metadataRevision
        let list = st.needsAppScan(revision: revision) ? nil : AppMaterializedList.load()
        let set = merge(system: system, appList: list)
        log.notice("capability refresh: system materialized set pages=\(pages, privacy: .public) seen=\(set.systemSeen, privacy: .public) candidates=\(set.counters.count(.candidate), privacy: .public)")
        log.notice("capability refresh: system filter: \(set.counters.filterLine, privacy: .public)")
        for line in set.samples.lines {
            log.notice("capability refresh: sample \(line, privacy: .public)")
        }
        if let list {
            log.notice("capability refresh: app scan (\(list.entries.count, privacy: .public) entries from \(list.createdAt.description, privacy: .public)): \(set.counters.appLine, privacy: .public)")
        } else {
            log.notice("capability refresh: no app scan list for \(revision, privacy: .public) yet (the app writes one after unlock; that bumps the generation and forces a new pass)")
        }
        return set
    }

    /// Pure merge of the system's materialized set and the app's on-disk list.
    static func merge(system: [NSFileProviderItem], appList: AppMaterializedList?) -> CollectedSet {
        var byId: [NSFileProviderItemIdentifier: MaterializedEntry] = [:]
        var current = Set<NSFileProviderItemIdentifier>()
        var counters = CapabilityRefreshCounters()
        var samples = FilterSamples()
        for item in system {
            let (reason, entry) = classified(item)
            counters.add(reason)
            samples.note(reason) { describe(item) }
            switch reason {
            case .candidate:
                if let entry { byId[entry.identifier] = entry }
            case .alreadyCurrent:
                current.insert(item.itemIdentifier)
            default:
                break
            }
        }
        var appCount = 0
        if let appList {
            for e in appList.entries {
                guard let m = entry(fromApp: e) else { counters.appUnparseable += 1; continue }
                if byId[m.identifier] != nil { counters.appDuplicateOfSystemCandidate += 1; continue }
                if current.contains(m.identifier) { counters.appAlreadyCurrentOnSystem += 1; continue }
                byId[m.identifier] = m
                appCount += 1
            }
            counters.appAdded = appCount
        }
        var set = CollectedSet(entries: Array(byId.values), systemSeen: system.count, appEntries: appCount)
        set.counters = counters
        set.samples = samples
        set.appListed = appList?.entries.count
        return set
    }

    /// Flags only (no file names): enough to tell which filter rule fired.
    static func describe(_ item: NSFileProviderItem) -> String {
        let raw = item.itemIdentifier.rawValue
        let idKind: String
        if item.itemIdentifier == .rootContainer { idKind = "root" }
        else if let cut = raw.firstIndex(where: { $0 == ":" || $0 == "(" }) { idKind = String(raw[...cut]) }
        else { idKind = String(raw.prefix(12)) }
        func b(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "nil" }
        let meta = item.itemVersion.map { String(decoding: $0.metadataVersion.prefix(16), as: UTF8.self) } ?? "nil"
        return "id=\(idKind) downloaded=\(b(item.isDownloaded)) uploaded=\(b(item.isUploaded)) uploading=\(b(item.isUploading)) caps=\(item.capabilities.map { String($0.rawValue) } ?? "nil") meta=\(meta)"
    }

    /// Entry from the app's on-disk scan. No content version: matched by size.
    static func entry(fromApp e: AppMaterializedList.Entry) -> MaterializedEntry? {
        let id = NSFileProviderItemIdentifier(e.identifier)
        let kind: WorkingSetRefresh.ItemKind
        let parentDirId: String?
        let ownKey: String
        switch ItemID.parse(id) {
        case .root?:
            kind = .root; parentDirId = nil; ownKey = ""
        case .directory(let dirId, let parent?)?:
            guard e.isDirectory else { return nil }
            kind = .directory; parentDirId = parent; ownKey = dirId
        case .file(let parent, let cipherName)?:
            guard !e.isDirectory else { return nil }
            kind = .file; parentDirId = parent; ownKey = cipherName
        default:
            return nil
        }
        return MaterializedEntry(
            identifier: id,
            parent: NSFileProviderItemIdentifier(e.parent),
            filename: e.filename,
            kind: kind,
            parentDirId: parentDirId,
            ownKey: ownKey,
            documentSize: e.isDirectory ? nil : e.size,
            contentVersion: nil
        )
    }

    /// Maps a system item to a refresh entry, or nil when it must be left alone.
    static func entry(for item: NSFileProviderItem) -> MaterializedEntry? {
        let (reason, e) = classified(item)
        return reason == .candidate ? e : nil
    }

    static func classified(_ item: NSFileProviderItem) -> (WorkingSetRefresh.FilterReason, MaterializedEntry?) {
        let id = item.itemIdentifier
        if id == .trashContainer || id == .workingSet { return (.systemContainer, nil) }
        var kind: WorkingSetRefresh.ItemKind?
        var parentDirId: String?
        var ownKey = ""
        switch ItemID.parse(id) {
        case .root?:
            kind = .root
        case .directory(let dirId, let parent?)?:
            kind = .directory; parentDirId = parent; ownKey = dirId
        case .file(let parent, let cipherName)?:
            kind = .file; parentDirId = parent; ownKey = cipherName
        default:
            // Legacy / system-internal identifiers: never invent an update for them.
            kind = nil
        }
        let version = item.itemVersion
        let reason = WorkingSetRefresh.classify(
            kind: kind,
            isDownloaded: kind == .file ? item.isDownloaded : nil,
            isUploaded: item.isUploaded,
            isUploading: item.isUploading,
            hasUnresolvedConflicts: nil, // not exposed on macOS items; fileproviderd refuses evicting conflicts anyway
            capabilities: item.capabilities,
            metadataVersion: version?.metadataVersion,
            contentVersion: version?.contentVersion
        )
        guard reason == .candidate, let kind else { return (reason, nil) }
        let size: NSNumber? = item.documentSize ?? nil
        return (reason, MaterializedEntry(
            identifier: id,
            parent: item.parentItemIdentifier,
            filename: item.filename,
            kind: kind,
            parentDirId: parentDirId,
            ownKey: ownKey,
            documentSize: size?.int64Value,
            contentVersion: version?.contentVersion
        ))
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
/// capability refresh (see `WorkingSetRefresh`). Metadata-only: an item is
/// reported only when remote truth has the same identifier, parent, name and
/// content the system already has, so nothing re-downloads, nothing is
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
            log.notice("capability refresh: working set asked for changes; nothing needed (state=\(st.completedRevision ?? "none", privacy: .public) gen \(st.completedGeneration, privacy: .public)/\(st.requestedGeneration, privacy: .public))")
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        let anchorState = WorkingSetRefresh.state(of: anchor.rawValue)
        task = Task { [refresher, index, domainDisplayName] in
            // A newer app request (scan list landed / menu) invalidates an older snapshot.
            _ = await refresher.dropIfStale(requestedGeneration: st.requestedGeneration)
            guard let snapshot = await refresher.snapshot else {
                log.notice("capability refresh: needed (revision \(revision, privacy: .public), done=\(st.completedRevision ?? "none", privacy: .public) gen \(st.completedGeneration, privacy: .public)/\(st.requestedGeneration, privacy: .public)); starting collection")
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
            var pageCounters = CapabilityRefreshCounters()
            let rootNow = start == 0 && snapshot.root != nil
            if rootNow {
                updated.append(VaultItem.root(displayName: domainDisplayName))
            }
            let end = min(start + WorkingSetRefresh.groupsPerPage, snapshot.groups.count)
            var listFailures = 0
            if start < end {
                for group in snapshot.groups[start..<end] {
                    if Task.isCancelled { return }
                    do {
                        let nodes = try await session.list(dirId: group.parentDirId)
                        let (items, c) = Self.match(group: group, listing: nodes)
                        updated.append(contentsOf: items)
                        for (k, v) in c.match { pageCounters.add(k, v) }
                    } catch {
                        listFailures += 1
                        pageCounters.add(.listingFailed, group.entries.count)
                        await refresher.markGroupFailed()
                    }
                }
            }
            await refresher.addMatch(pageCounters, root: rootNow)
            var i = 0
            while i < updated.count {
                observer.didUpdate(Array(updated[i..<min(i + 500, updated.count)]))
                i += 500
            }
            log.notice("capability refresh: folders \(start, privacy: .public)..<\(end, privacy: .public) of \(snapshot.groups.count, privacy: .public): reported \(updated.count, privacy: .public) update(s) (\(pageCounters.matchLine, privacy: .public)), listing failures \(listFailures, privacy: .public)")
            if end < snapshot.groups.count {
                await refresher.markServedPartial()
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(WorkingSetRefresh.partialAnchor(nextGroup: end)),
                    moreComing: true
                )
                return
            }
            let generation = await refresher.snapshotGeneration
            let passMatch = await refresher.matchCounters
            let updatedRoot = await refresher.updatedRootInPass
            let failed = await refresher.finishPass()
            log.notice("capability refresh: pass match totals: \(passMatch.matchLine, privacy: .public)")
            let retryAnchor = NSFileProviderSyncAnchor(Data("ws-retry|\(Date().timeIntervalSince1970)".utf8))
            if failed {
                await refresher.noteRetry(generation: generation)
                log.error("capability refresh: NOT complete — some folders could not be listed; retrying in \(Int(CapabilityRefresher.retryBackoff), privacy: .public)s")
                CapabilityRefreshState.update { $0.lastStatus = "partial: some folders could not be listed, will retry"; $0.lastStatusAt = Date() }
                observer.finishEnumeratingChanges(upTo: retryAnchor, moreComing: false)
                return
            }
            let latest = CapabilityRefreshState.load()
            let stats = CapabilityRefreshPassStats(
                systemSeen: snapshot.systemSeen,
                systemAlreadyCurrent: snapshot.counters.count(.alreadyCurrent),
                systemContainers: snapshot.counters.count(.systemContainer),
                candidates: snapshot.itemCount,
                nonRootCandidates: snapshot.nonRootCount,
                updatedNonRoot: passMatch.count(.updated),
                updatedRoot: updatedRoot,
                appMaterialized: snapshot.appListed
            )
            let outcome = CapabilityRefreshOutcome.decide(stats)
            switch outcome {
            case .retry(let why):
                await refresher.noteRetry(generation: generation)
                log.error("capability refresh: NOT complete — \(why, privacy: .public) (candidates \(stats.candidates, privacy: .public), updated \(stats.updatedNonRoot, privacy: .public), system seen \(stats.systemSeen, privacy: .public), app \(stats.appMaterialized.map(String.init) ?? "none", privacy: .public)); retrying in \(Int(CapabilityRefresher.retryBackoff), privacy: .public)s or on the next app signal")
                CapabilityRefreshState.update { $0.lastStatus = "retrying: \(why)"; $0.lastStatusAt = Date() }
                observer.finishEnumeratingChanges(upTo: retryAnchor, moreComing: false)
            case .complete(let why):
                let done = CapabilityRefreshState.update {
                    $0.markCompleted(revision: revision, generation: generation, status: "done: \(why) (system \(stats.systemSeen), app \(stats.appMaterialized.map(String.init) ?? "none"))")
                }
                log.notice("capability refresh: pass complete — \(why, privacy: .public) (revision \(revision, privacy: .public), generation \(generation, privacy: .public))")
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(done.completedAnchor(revision: revision)),
                    moreComing: false
                )
                if latest.requestedGeneration > generation || done.needsRefresh(revision: revision) {
                    // An app request arrived during this pass: run another one.
                    await refresher.signalSoon(why: "request \(done.requestedGeneration) arrived during pass \(generation)")
                }
            }
        }
    }

    /// Same bytes as the local copy: ETag equality when the system gave us a content
    /// version; otherwise (app scan) the remote ciphertext must decode to exactly
    /// the local cleartext size.
    static func sameContent(entry e: MaterializedEntry, node: VaultNode) -> Bool {
        if let cv = e.contentVersion {
            return Data((node.eTag ?? "0").utf8) == cv
        }
        guard let local = e.documentSize, let cipher = node.size,
              let clear = CryptomatorSize.cleartextSize(ciphertext: cipher)
        else { return false }
        return clear == local
    }

    /// Metadata-only updates for one directory's materialized entries.
    static func items(for group: RefreshSnapshot.Group, listing nodes: [VaultNode]) -> [NSFileProviderItem] {
        match(group: group, listing: nodes).0
    }

    /// Updates plus per-reason match counters for one directory.
    static func match(group: RefreshSnapshot.Group, listing nodes: [VaultNode]) -> ([NSFileProviderItem], CapabilityRefreshCounters) {
        var out: [NSFileProviderItem] = []
        var c = CapabilityRefreshCounters()
        for e in group.entries {
            switch e.kind {
            case .file:
                guard let node = nodes.first(where: { $0.kind == .file && $0.cipherName == e.ownKey }) else { c.add(.notOnVault); continue }
                guard ItemID.node(node) == e.identifier else { c.add(.identifierMismatch); continue }
                guard node.cleartextName == e.filename else { c.add(.nameMismatch); continue }
                guard Self.sameContent(entry: e, node: node) else { c.add(.contentMismatch); continue }
                out.append(
                    VaultItem.file(
                        node: node,
                        parentItemIdentifier: e.parent,
                        documentSize: e.documentSize.map { NSNumber(value: $0) },
                        downloaded: true
                    )
                )
                c.add(.updated)
            case .directory:
                guard let node = nodes.first(where: { $0.kind == .directory && $0.dirId == e.ownKey }) else { c.add(.notOnVault); continue }
                guard node.cleartextName == e.filename else { c.add(.nameMismatch); continue }
                let item = VaultItem.directory(
                    dirId: e.ownKey,
                    parentDirId: group.parentDirId,
                    name: node.cleartextName,
                    parentItemIdentifier: e.parent
                )
                guard item.itemIdentifier == e.identifier else { c.add(.identifierMismatch); continue }
                out.append(item)
                c.add(.updated)
            case .root:
                continue
            }
        }
        return (out, c)
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
