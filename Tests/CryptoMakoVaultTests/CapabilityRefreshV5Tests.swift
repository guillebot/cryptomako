@testable import CryptoMakoFileProvider
import CryptoMakoShared
@testable import CryptoMakoVault
import FileProvider
import XCTest

/// Stand-in for an item from `enumeratorForMaterializedItems()`, shaped like
/// what `fileproviderctl evaluate` printed on Guillermo's Mac on Nov 24.
final class FakeSystemItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    private let dlFlag: Bool
    private let upFlag: Bool
    private let upingFlag: Bool
    var isDownloaded: Bool { dlFlag }
    var isUploaded: Bool { upFlag }
    var isUploading: Bool { upingFlag }

    init(id: String, parent: String = "NSFileProviderRootContainerItemIdentifier", filename: String = "x",
         caps: UInt, size: Int64? = nil, content: String, meta: String,
         downloaded: Bool = true, uploaded: Bool = true, uploading: Bool = false) {
        itemIdentifier = NSFileProviderItemIdentifier(id)
        parentItemIdentifier = NSFileProviderItemIdentifier(parent)
        self.filename = filename
        capabilities = NSFileProviderItemCapabilities(rawValue: caps)
        documentSize = size.map { NSNumber(value: $0) }
        itemVersion = NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(meta.utf8))
        dlFlag = downloaded
        upFlag = uploaded
        upingFlag = uploading
    }
}

/// Reproduces the 1.0.20 failure log of Nov 24 (12:00:35–12:15 UTC−3) step by step.
final class CapabilityRefreshV5Tests: XCTestCase {
    let rev = FileProviderCapabilitySets.metadataRevision
    /// Values fileproviderctl reported (files / folders / root).
    static let fileCaps: UInt = 536_870_959
    static let dirCaps: UInt = 603_979_823
    static let rootCaps: UInt = 603_979_779
    static let files = 18_031
    static let folders = 59_725

    // MARK: - Fixtures

    private func dirId(_ i: Int) -> String { String(format: "D%07d-0000-0000-0000-000000000000", i) }

    /// Guillermo's set with OUR identifiers (what `evaluate` shows): root, trash,
    /// 59,725 folders, 18,031 files = 77,758 items.
    private func evaluateShapedSystemSet() -> [NSFileProviderItem] {
        var out: [NSFileProviderItem] = [
            FakeSystemItem(id: "NSFileProviderRootContainerItemIdentifier", caps: Self.rootCaps, content: "dir-v2", meta: "caps-delete-v2"),
            FakeSystemItem(id: "NSFileProviderTrashContainerItemIdentifier", caps: Self.rootCaps, content: "dir-v2", meta: "caps-delete-v2"),
        ]
        for i in 0..<Self.folders {
            out.append(FakeSystemItem(id: "d:/\(dirId(i))", caps: Self.dirCaps, content: "dir-v2", meta: "caps-delete-v2"))
        }
        for i in 0..<Self.files {
            let p = dirId(i % 50)
            out.append(FakeSystemItem(id: "f:\(p)/c\(i).c9r", parent: "d:/\(p)", filename: "f\(i).jpg",
                                      caps: Self.fileCaps, size: 162_674, content: "etag\(i)", meta: "etag\(i)"))
        }
        return out
    }

    /// Same set, but with system-internal references instead of our identifiers
    /// (fileproviderd's own `__fp/fs/fileID(…)` form, as seen in `fileproviderctl dump`).
    private func internalIdSystemSet() -> [NSFileProviderItem] {
        (0..<(Self.files + Self.folders + 2)).map { i in
            FakeSystemItem(id: "__fp/fs/fileID(\(82_559_516 + i))", caps: Self.fileCaps, content: "c", meta: "m")
        }
    }

    /// What the app wrote at 12:02:38: 18,031 files + 59,725 folders, all resolved to our ids.
    private func appList() -> AppMaterializedList {
        var entries: [AppMaterializedList.Entry] = []
        for i in 0..<Self.folders {
            entries.append(.init(identifier: "d:/\(dirId(i))", parent: "NSFileProviderRootContainerItemIdentifier",
                                 filename: "dir\(i)", isDirectory: true, size: 0))
        }
        for i in 0..<Self.files {
            let p = dirId(i % 50)
            entries.append(.init(identifier: "f:\(p)/c\(i).c9r", parent: "d:/\(p)", filename: "f\(i).jpg",
                                 isDirectory: false, size: 162_674))
        }
        return AppMaterializedList(createdAt: Date(), entries: entries)
    }

    private func stats(_ snap: RefreshSnapshot, updated: Int) -> CapabilityRefreshPassStats {
        CapabilityRefreshPassStats(
            systemSeen: snap.systemSeen,
            systemAlreadyCurrent: snap.counters.count(.alreadyCurrent),
            systemContainers: snap.counters.count(.systemContainer),
            candidates: snap.itemCount,
            nonRootCandidates: snap.nonRootCount,
            updatedNonRoot: updated,
            appMaterialized: snap.appListed
        )
    }

    // MARK: - The exact 1.0.20 sequence

    func testNov24LogSequenceNoLongerCompletesWithoutUpdates() {
        // 12:00:35 extension started; needed=true state=none gen 0/0
        var st = CapabilityRefreshState()
        XCTAssertTrue(st.needsRefresh(revision: rev))
        XCTAssertEqual(st.requestedGeneration, 0)

        // 12:01:24 system materialized set seen=77758 candidates=0; no app scan list yet.
        let system = internalIdSystemSet()
        XCTAssertEqual(system.count, 77_758)
        let first = CapabilityRefresher.merge(system: system, appList: nil)
        XCTAssertEqual(first.entries.count, 0, "collected 0 item(s) needing update")
        // (b) every rejection is now counted with its reason.
        XCTAssertEqual(first.counters.count(.unparseableIdentifier), 77_758)
        XCTAssertTrue(first.counters.filterLine.contains("unparseableIdentifier=77758"))
        XCTAssertTrue(first.samples.lines.allSatisfy { $0.hasPrefix("unparseableIdentifier: id=__fp/fs/fileID(") })
        XCTAssertNil(first.appListed)

        // 12:01:25 1.0.20 said "pass complete (0 candidate item(s))". (c) Now: retry.
        let snap1 = RefreshSnapshot(collected: first)
        let out1 = CapabilityRefreshOutcome.decide(stats(snap1, updated: 0))
        XCTAssertFalse(out1.isComplete)
        guard case .retry(let why) = out1 else { return XCTFail() }
        XCTAssertTrue(why.contains("not listed"), why)
        // markCompleted is NOT called on retry → still needed.
        XCTAssertTrue(st.needsRefresh(revision: rev))

        // 12:02:38 app: 18031 downloaded file(s), 59725 folder(s); signalling working set.
        st.recordAppScan(count: Self.files + Self.folders, revision: rev)
        // (a) the list arriving bumps the generation → a NEW pass is forced.
        XCTAssertEqual(st.requestedGeneration, 1)
        XCTAssertTrue(st.needsRefresh(revision: rev))
        XCTAssertFalse(st.needsAppScan(revision: rev))
        XCTAssertTrue(CapabilityRefreshPlanner.bypassBackoff(generation: 1, lastFailureGeneration: 0),
                      "the app's signal must not wait out the 5-minute retry backoff")

        // Next pass includes the app list → every downloaded item is a candidate.
        let second = CapabilityRefresher.merge(system: system, appList: appList())
        XCTAssertEqual(second.counters.appAdded, Self.files + Self.folders)
        let snap2 = RefreshSnapshot(collected: second)
        XCTAssertEqual(snap2.nonRootCount, Self.files + Self.folders)
        XCTAssertEqual(snap2.appListed, Self.files + Self.folders)
        // Still 0 updates (e.g. vault unreachable) → never complete.
        XCTAssertFalse(CapabilityRefreshOutcome.decide(stats(snap2, updated: 0)).isComplete)
        // Updates handed to fileproviderd → complete, and only then recorded.
        let out2 = CapabilityRefreshOutcome.decide(stats(snap2, updated: 77_700))
        XCTAssertTrue(out2.isComplete)
        st.markCompleted(revision: rev, generation: 1, status: "done")
        XCTAssertFalse(st.needsRefresh(revision: rev))
    }

    func testRaceAppScanLandsAfterA1020StyleCompletion() {
        // Even if a pass for this revision had completed at generation 0 (as 1.0.20
        // recorded), the scan list arriving forces another pass.
        var st = CapabilityRefreshState()
        st.markCompleted(revision: rev, generation: 0, status: "done: 0 of 0 item(s) refreshed (system 77758, app 0)")
        XCTAssertFalse(st.needsRefresh(revision: rev))
        st.recordAppScan(count: 77_756, revision: rev)
        XCTAssertTrue(st.needsRefresh(revision: rev))
        XCTAssertTrue(st.lastStatus?.contains("app scan ready: 77756") ?? false)
        // A snapshot collected for generation 0 is rebuilt so it includes the list…
        XCTAssertTrue(CapabilityRefreshPlanner.snapshotIsStale(snapshotGeneration: 0, requestedGeneration: 1, servedPartial: false))
        // …unless a paged pass is mid-flight (it finishes, then a follow-up pass runs).
        XCTAssertFalse(CapabilityRefreshPlanner.snapshotIsStale(snapshotGeneration: 0, requestedGeneration: 1, servedPartial: true))
        XCTAssertFalse(CapabilityRefreshPlanner.snapshotIsStale(snapshotGeneration: 1, requestedGeneration: 1, servedPartial: false))
        // Same generation after a failure keeps the backoff.
        XCTAssertFalse(CapabilityRefreshPlanner.bypassBackoff(generation: 1, lastFailureGeneration: 1))
    }

    func testEvaluateShapedItemsAreAllCandidates() {
        // With our identifiers and the caps fileproviderctl printed, nothing is filtered out.
        let set = CapabilityRefresher.merge(system: evaluateShapedSystemSet(), appList: nil)
        XCTAssertEqual(set.systemSeen, 77_758)
        XCTAssertEqual(set.counters.count(.systemContainer), 1) // trash
        XCTAssertEqual(set.counters.count(.candidate), 77_757)  // root + folders + files
        XCTAssertEqual(set.entries.count, 77_757)
        XCTAssertTrue(set.samples.lines.allSatisfy { !$0.contains("f1.jpg") }, "samples never include file names")
    }

    // MARK: - Candidate filter

    func testAnyDownloadedItemLackingEvictingIsACandidate() {
        let staleCaps = NSFileProviderItemCapabilities(rawValue: Self.fileCaps)
        // Even with the CURRENT metadata version, missing .allowsEvicting → candidate.
        let currentMeta = FileProviderCapabilitySets.fileMetadataVersion(eTag: "e")
        XCTAssertEqual(WorkingSetRefresh.classify(kind: .file, isDownloaded: true, isUploaded: true, isUploading: false,
                                                  hasUnresolvedConflicts: nil, capabilities: staleCaps,
                                                  metadataVersion: currentMeta, contentVersion: Data("e".utf8)), .candidate)
        // Unknown (nil) properties never reject.
        XCTAssertEqual(WorkingSetRefresh.classify(kind: .file, isDownloaded: nil, isUploaded: nil, isUploading: nil,
                                                  hasUnresolvedConflicts: nil, capabilities: nil,
                                                  metadataVersion: nil, contentVersion: nil), .candidate)
        // Has .allowsEvicting but old metadata → still refreshed.
        XCTAssertEqual(WorkingSetRefresh.classify(kind: .directory, isDownloaded: nil, isUploaded: true, isUploading: false,
                                                  hasUnresolvedConflicts: nil, capabilities: FileProviderCapabilitySets.directory,
                                                  metadataVersion: Data("caps-delete-v2".utf8), contentVersion: nil), .candidate)
        // Only explicit states reject, each with its own reason.
        func r(_ kind: WorkingSetRefresh.ItemKind?, dl: Bool? = true, up: Bool? = true, uping: Bool? = false, conflict: Bool? = nil) -> WorkingSetRefresh.FilterReason {
            WorkingSetRefresh.classify(kind: kind, isDownloaded: dl, isUploaded: up, isUploading: uping,
                                       hasUnresolvedConflicts: conflict, capabilities: staleCaps,
                                       metadataVersion: nil, contentVersion: nil)
        }
        XCTAssertEqual(r(nil), .unparseableIdentifier)
        XCTAssertEqual(r(.file, dl: false), .notDownloaded)
        XCTAssertEqual(r(.directory, dl: false), .candidate, "isDownloaded is ignored for folders")
        XCTAssertEqual(r(.file, uping: true), .uploading)
        XCTAssertEqual(r(.file, up: false), .notUploaded)
        XCTAssertEqual(r(.file, conflict: true), .conflict)
        XCTAssertEqual(WorkingSetRefresh.classify(kind: .file, isSystemContainer: true, isDownloaded: true, isUploaded: true,
                                                  isUploading: false, hasUnresolvedConflicts: nil, capabilities: staleCaps,
                                                  metadataVersion: nil, contentVersion: nil), .systemContainer)
        // Already current = evicting + current metadata.
        XCTAssertEqual(WorkingSetRefresh.classify(kind: .file, isDownloaded: true, isUploaded: true, isUploading: false,
                                                  hasUnresolvedConflicts: nil, capabilities: FileProviderCapabilitySets.file,
                                                  metadataVersion: currentMeta, contentVersion: Data("e".utf8)), .alreadyCurrent)
    }

    func testAppEntriesDedupAgainstSystemAndCountReasons() {
        let p = dirId(1)
        let current = FakeSystemItem(id: "f:\(p)/ok.c9r", parent: "d:/\(p)", caps: FileProviderCapabilitySets.file.rawValue,
                                     size: 10, content: "e", meta: String(decoding: FileProviderCapabilitySets.fileMetadataVersion(eTag: "e"), as: UTF8.self))
        let stale = FakeSystemItem(id: "f:\(p)/stale.c9r", parent: "d:/\(p)", caps: Self.fileCaps, size: 10, content: "e2", meta: "e2")
        let pending = FakeSystemItem(id: "f:\(p)/pending.c9r", parent: "d:/\(p)", caps: Self.fileCaps, size: 10, content: "e3", meta: "e3", uploaded: false)
        let list = AppMaterializedList(entries: [
            .init(identifier: "f:\(p)/ok.c9r", parent: "d:/\(p)", filename: "ok", isDirectory: false, size: 10),
            .init(identifier: "f:\(p)/stale.c9r", parent: "d:/\(p)", filename: "stale", isDirectory: false, size: 10),
            .init(identifier: "f:\(p)/new.c9r", parent: "d:/\(p)", filename: "new", isDirectory: false, size: 10),
            .init(identifier: "garbage", parent: "d:/\(p)", filename: "g", isDirectory: false, size: 10),
        ])
        let set = CapabilityRefresher.merge(system: [current, stale, pending], appList: list)
        XCTAssertEqual(set.counters.count(.alreadyCurrent), 1)
        XCTAssertEqual(set.counters.count(.candidate), 1)
        XCTAssertEqual(set.counters.count(.notUploaded), 1)
        XCTAssertEqual(set.counters.appAlreadyCurrentOnSystem, 1)
        XCTAssertEqual(set.counters.appDuplicateOfSystemCandidate, 1)
        XCTAssertEqual(set.counters.appUnparseable, 1)
        XCTAssertEqual(set.counters.appAdded, 1)
        XCTAssertEqual(Set(set.entries.map(\.identifier.rawValue)), ["f:\(p)/stale.c9r", "f:\(p)/new.c9r"])
        XCTAssertTrue(set.samples.lines.contains { $0.hasPrefix("notUploaded: id=f: downloaded=1 uploaded=0") }, set.samples.lines.joined(separator: "\n"))
        XCTAssertTrue(set.counters.appLine.contains("added=1"))
    }

    // MARK: - Completion rule

    func testCompletionRule() {
        typealias S = CapabilityRefreshPassStats
        // Only the root was updated while 77k items matched nothing → retry.
        XCTAssertFalse(CapabilityRefreshOutcome.decide(S(systemSeen: 77_758, candidates: 77_757, nonRootCandidates: 77_756,
                                                         updatedNonRoot: 0, updatedRoot: true, appMaterialized: 77_756)).isComplete)
        // Root-only candidate with an app list that found things → retry (unexplained).
        XCTAssertFalse(CapabilityRefreshOutcome.decide(S(systemSeen: 77_758, candidates: 1, nonRootCandidates: 0,
                                                         updatedRoot: true, appMaterialized: 77_756)).isComplete)
        // Truly empty: system lists nothing (or only containers) and the app found nothing.
        XCTAssertTrue(CapabilityRefreshOutcome.decide(S(systemSeen: 1, systemContainers: 1, appMaterialized: 0)).isComplete)
        XCTAssertFalse(CapabilityRefreshOutcome.decide(S(systemSeen: 0, appMaterialized: nil)).isComplete)
        XCTAssertFalse(CapabilityRefreshOutcome.decide(S(systemSeen: 0, appMaterialized: 5)).isComplete)
        // Verified current item by item (nothing lacks .allowsEvicting) → complete.
        XCTAssertTrue(CapabilityRefreshOutcome.decide(S(systemSeen: 901, systemAlreadyCurrent: 900, systemContainers: 1, appMaterialized: 900)).isComplete)
        // One unexplained rejection breaks "verified current".
        XCTAssertFalse(CapabilityRefreshOutcome.decide(S(systemSeen: 901, systemAlreadyCurrent: 899, systemContainers: 1, appMaterialized: 900)).isComplete)
    }

    // MARK: - Match counters

    func testMatchCountersExplainEveryCandidate() {
        let parentDir = "84AFAFAF-A46D-46AD-A51F-2D49090F5819"
        func node(_ c: String, _ name: String, _ etag: String) -> VaultNode {
            VaultNode(cleartextName: name, kind: .file, cipherName: c, parentDirId: parentDir, dirId: nil,
                      ciphertextKey: "k", size: CryptomatorSize.ciphertextSize(cleartext: 100), eTag: etag)
        }
        func entry(_ n: VaultNode, cv: String?, name: String? = nil, size: Int64 = 100) -> MaterializedEntry {
            MaterializedEntry(identifier: ItemID.node(n), parent: NSFileProviderItemIdentifier("d:/\(parentDir)"),
                              filename: name ?? n.cleartextName, kind: .file, parentDirId: parentDir, ownKey: n.cipherName,
                              documentSize: size, contentVersion: cv.map { Data($0.utf8) })
        }
        let a = node("a.c9r", "a", "1"), b = node("b.c9r", "b", "2"), c = node("c.c9r", "c", "3"), gone = node("g.c9r", "g", "4")
        let group = RefreshSnapshot.Group(parentDirId: parentDir, entries: [
            entry(a, cv: "1"),               // updated
            entry(b, cv: "old"),             // content changed remotely
            entry(c, cv: nil, name: "local"),// renamed locally
            entry(gone, cv: "4"),            // not on vault
            entry(a, cv: nil, size: 100),    // app entry, size matches → updated
        ])
        let (items, counters) = WorkingSetEnumerator.match(group: group, listing: [a, b, c])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(counters.count(.updated), 2)
        XCTAssertEqual(counters.count(.contentMismatch), 1)
        XCTAssertEqual(counters.count(.nameMismatch), 1)
        XCTAssertEqual(counters.count(.notOnVault), 1)
        XCTAssertTrue(items.allSatisfy { $0.capabilities?.contains(.allowsEvicting) ?? false })
        XCTAssertEqual(counters.matchLine, "updated=2 notOnVault=1 contentMismatch=1 nameMismatch=1 identifierMismatch=0 listingFailed=0")
    }

    // MARK: - State

    func testRevisionBumpAndLenientDecode() throws {
        XCTAssertEqual(rev, "caps-evict-v5")
        // The 1.0.20 file on Guillermo's Mac, verbatim: completed v4 → needed again in 1.0.21, rescan too.
        let json = #"{"requestedGeneration":0,"lastStatus":"done: 0 of 0 item(s) refreshed (system 77758, app 0)","completedGeneration":0,"appMaterializedCount":77756,"lastStatusAt":817225285.587716,"completedRevision":"caps-evict-v4"}"#
        let st = try JSONDecoder().decode(CapabilityRefreshState.self, from: Data(json.utf8))
        XCTAssertTrue(st.needsRefresh(revision: rev))
        XCTAssertTrue(st.needsAppScan(revision: rev), "a list from 1.0.20 is not reused")
        XCTAssertNil(st.appScanAt)
        var s2 = st
        s2.recordAppScan(count: 3, revision: rev)
        let round = try JSONDecoder().decode(CapabilityRefreshState.self, from: JSONEncoder().encode(s2))
        XCTAssertEqual(round.appScanRevision, rev)
        XCTAssertEqual(round.requestedGeneration, 1)
    }
}
