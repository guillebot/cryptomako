@testable import CryptoMakoFileProvider
import CryptoMakoShared
@testable import CryptoMakoVault
import FileProvider
import XCTest

final class WorkingSetRefreshAnchorTests: XCTestCase {
    func testLegacyEmptyAnchorIsStale() {
        // Pre-1.0.18 working set always answered "empty" → every install upgrades.
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("empty".utf8)), .stale)
        XCTAssertEqual(WorkingSetRefresh.state(of: Data()), .stale)
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("ws-retry".utf8)), .stale)
    }

    func testCurrentAnchorEmbedsRevision() {
        let a = WorkingSetRefresh.currentAnchor
        XCTAssertEqual(WorkingSetRefresh.state(of: a), .current)
        XCTAssertTrue(String(decoding: a, as: UTF8.self).contains(FileProviderCapabilitySets.metadataRevision))
        // An older revision must trigger another refresh.
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("ws|caps-evict-v2".utf8)), .stale)
    }

    func testPartialAnchorRoundTrip() {
        XCTAssertEqual(WorkingSetRefresh.state(of: WorkingSetRefresh.partialAnchor(nextGroup: 80)), .partial(nextGroup: 80))
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("wsp|caps-evict-v2|80".utf8)), .stale)
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("wsp|\(FileProviderCapabilitySets.metadataRevision)|x".utf8)), .stale)
        XCTAssertEqual(WorkingSetRefresh.state(of: Data("wsp|\(FileProviderCapabilitySets.metadataRevision)|-1".utf8)), .stale)
    }
}

final class WorkingSetRefreshFilterTests: XCTestCase {
    /// Capabilities fileproviderctl reported on Guillermo's materialized files in 1.0.17.
    let staleCaps = NSFileProviderItemCapabilities(rawValue: 536_870_959)
    let etag = Data("f4adaedfd61e88ea".utf8)

    func testStaleMaterializedFileNeedsRefresh() {
        XCTAssertEqual(staleCaps.rawValue & 64, 0)
        XCTAssertTrue(WorkingSetRefresh.needsRefresh(
            kind: .file, isDownloaded: true, isUploaded: true, isUploading: false,
            hasUnresolvedConflicts: nil, capabilities: staleCaps,
            metadataVersion: etag, contentVersion: etag
        ))
    }

    func testUpToDateFileIsSkipped() {
        let meta = WorkingSetRefresh.expectedMetadataVersion(kind: .file, contentVersion: etag)
        XCTAssertEqual(meta, FileProviderCapabilitySets.fileMetadataVersion(eTag: "f4adaedfd61e88ea"))
        XCTAssertFalse(WorkingSetRefresh.needsRefresh(
            kind: .file, isDownloaded: true, isUploaded: true, isUploading: false,
            hasUnresolvedConflicts: nil, capabilities: FileProviderCapabilitySets.file,
            metadataVersion: meta, contentVersion: etag
        ))
    }

    func testPendingOrDatalessOrUnknownAreLeftAlone() {
        for (dl, up, uping, conflict) in [
            (true, false, false, false as Bool?), // not uploaded (local edit)
            (true, true, true, false),            // uploading
            (true, true, false, true),            // conflict
            (false, true, false, false),          // dataless placeholder
        ] as [(Bool?, Bool?, Bool?, Bool?)] {
            XCTAssertFalse(WorkingSetRefresh.needsRefresh(
                kind: .file, isDownloaded: dl, isUploaded: up, isUploading: uping,
                hasUnresolvedConflicts: conflict, capabilities: staleCaps,
                metadataVersion: etag, contentVersion: etag
            ))
        }
        XCTAssertFalse(WorkingSetRefresh.needsRefresh(
            kind: nil, isDownloaded: true, isUploaded: true, isUploading: false,
            hasUnresolvedConflicts: nil, capabilities: staleCaps, metadataVersion: nil, contentVersion: nil
        ))
    }

    func testFoldersUseRevisionMetadata() {
        XCTAssertEqual(
            WorkingSetRefresh.expectedMetadataVersion(kind: .directory, contentVersion: nil),
            Data(FileProviderCapabilitySets.metadataRevision.utf8)
        )
        XCTAssertTrue(WorkingSetRefresh.needsRefresh(
            kind: .directory, isDownloaded: nil, isUploaded: true, isUploading: nil,
            hasUnresolvedConflicts: nil, capabilities: nil, metadataVersion: nil, contentVersion: nil
        ))
    }
}

final class WorkingSetRefreshMappingTests: XCTestCase {
    let parentDir = "84AFAFAF-A46D-46AD-A51F-2D49090F5819"
    let grandParent = "853368EF-BD03-4529-8962-744978B4CC76"

    private func fileNode(_ cipher: String, name: String, eTag: String?) -> VaultNode {
        VaultNode(cleartextName: name, kind: .file, cipherName: cipher, parentDirId: parentDir,
                  dirId: nil, ciphertextKey: "k/\(cipher)", size: 999, eTag: eTag)
    }

    private func entry(for node: VaultNode, contentVersion: String?, filename: String? = nil) -> MaterializedEntry {
        MaterializedEntry(
            identifier: ItemID.node(node),
            parent: NSFileProviderItemIdentifier("d:\(grandParent)/\(parentDir)"),
            filename: filename ?? node.cleartextName,
            kind: .file,
            parentDirId: parentDir,
            ownKey: node.cipherName,
            documentSize: 1553,
            contentVersion: contentVersion.map { Data($0.utf8) }
        )
    }

    func testSameContentProducesMetadataOnlyUpdateWithEvicting() throws {
        let node = fileNode("abc.c9r", name: "x.xmp", eTag: "e1")
        let group = RefreshSnapshot.Group(parentDirId: parentDir, entries: [entry(for: node, contentVersion: "e1")])
        let items = WorkingSetEnumerator.items(for: group, listing: [node])
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.itemIdentifier, ItemID.node(node))
        // Parent kept exactly as the system has it (no reparenting).
        XCTAssertEqual(item.parentItemIdentifier.rawValue, "d:\(grandParent)/\(parentDir)")
        XCTAssertTrue(item.capabilities?.contains(.allowsEvicting) ?? false)
        XCTAssertEqual(item.itemVersion?.contentVersion, Data("e1".utf8))
        XCTAssertEqual(item.itemVersion?.metadataVersion, FileProviderCapabilitySets.fileMetadataVersion(eTag: "e1"))
        // Cleartext size the system already has, not ciphertext.
        XCTAssertEqual((item.documentSize ?? nil)?.int64Value, 1553)
    }

    func testRemoteContentChangeRenameOrMissingAreSkipped() {
        let node = fileNode("abc.c9r", name: "x.xmp", eTag: "e2")
        // Remote bytes changed since the system's copy → not ours to report.
        XCTAssertTrue(WorkingSetEnumerator.items(
            for: .init(parentDirId: parentDir, entries: [entry(for: node, contentVersion: "e1")]),
            listing: [node]
        ).isEmpty)
        // Name differs → never rename from here.
        XCTAssertTrue(WorkingSetEnumerator.items(
            for: .init(parentDirId: parentDir, entries: [entry(for: node, contentVersion: "e2", filename: "local.xmp")]),
            listing: [node]
        ).isEmpty)
        // Gone remotely → no update and (by design) no deletion either.
        XCTAssertTrue(WorkingSetEnumerator.items(
            for: .init(parentDirId: parentDir, entries: [entry(for: node, contentVersion: "e2")]),
            listing: []
        ).isEmpty)
    }

    func testDirectoryUpdateKeepsIdentifier() throws {
        let childDir = "C0FFEE00-0000-0000-0000-000000000001"
        let dirNode = VaultNode(cleartextName: "2013", kind: .directory, cipherName: "d.c9r",
                                parentDirId: parentDir, dirId: childDir, ciphertextKey: "", size: nil, eTag: nil)
        let e = MaterializedEntry(
            identifier: ItemID.directory(dirId: childDir, parentDirId: parentDir),
            parent: NSFileProviderItemIdentifier("d:\(grandParent)/\(parentDir)"),
            filename: "2013", kind: .directory, parentDirId: parentDir, ownKey: childDir,
            documentSize: nil, contentVersion: nil
        )
        let items = WorkingSetEnumerator.items(for: .init(parentDirId: parentDir, entries: [e]), listing: [dirNode])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.itemIdentifier, e.identifier)
        XCTAssertTrue(item.capabilities?.contains(.allowsEvicting) ?? false)
    }

    func testSnapshotGroupsByParentDirectory() {
        let a = fileNode("a.c9r", name: "a", eTag: "1")
        let b = fileNode("b.c9r", name: "b", eTag: "2")
        let root = MaterializedEntry(identifier: .rootContainer, parent: .rootContainer, filename: "CryptoMako",
                                     kind: .root, parentDirId: nil, ownKey: "", documentSize: nil, contentVersion: nil)
        let snap = RefreshSnapshot(entries: [entry(for: a, contentVersion: "1"), root, entry(for: b, contentVersion: "2")])
        XCTAssertNotNil(snap.root)
        XCTAssertEqual(snap.groups.count, 1)
        XCTAssertEqual(snap.groups.first?.entries.count, 2)
        XCTAssertEqual(snap.itemCount, 3)
    }
}

final class EvictionErrorExplainerTests: XCTestCase {
    func testCapabilityRefusalExplainsRefresh() {
        let msg = EvictionErrorExplainer.describe(domain: NSCocoaErrorDomain, code: 3328, localized: "The operation couldn’t be completed.")
        XCTAssertTrue(msg.contains("Remove Download permission"))
        XCTAssertTrue(msg.contains("NSCocoaErrorDomain 3328"))
        XCTAssertTrue(EvictionErrorExplainer.isCapabilityRefusal(domain: NSPOSIXErrorDomain, code: Int(EPERM)))
    }

    func testKnownFileProviderErrorsAndFallback() {
        XCTAssertTrue(EvictionErrorExplainer.describe(
            domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.notAuthenticated.rawValue, localized: "x"
        ).contains("vault is locked"))
        XCTAssertTrue(EvictionErrorExplainer.describe(
            domain: NSFileProviderErrorDomain, code: NSFileProviderError.Code.noSuchItem.rawValue, localized: "x"
        ).contains("no longer knows"))
        XCTAssertEqual(EvictionErrorExplainer.describe(domain: "Other", code: 7, localized: "boom"), "boom (Other 7)")
    }

    func testEarlyAbortOnlyWhenNothingEvicted() {
        var s = EvictionSummary()
        s.failed = EvictionSummary.earlyAbortFailures - 1
        XCTAssertFalse(s.shouldAbortEarly)
        s.failed += 1
        XCTAssertTrue(s.shouldAbortEarly)
        s.evictedFiles = 1
        XCTAssertFalse(s.shouldAbortEarly)
    }
}

final class CapabilityRefreshStateTests: XCTestCase {
    let rev = FileProviderCapabilitySets.metadataRevision

    func testFreshInstallNeedsRefreshRegardlessOfAnchor() {
        // 1.0.18 bug: fileproviderd already held the current anchor, so anchor-based
        // detection said "nothing to do". The shared state must still say refresh.
        XCTAssertTrue(CapabilityRefreshState().needsRefresh(revision: rev))
    }

    func testCompletionAndAppRequest() {
        var s = CapabilityRefreshState()
        s.markCompleted(revision: rev, generation: 0, status: "done")
        XCTAssertFalse(s.needsRefresh(revision: rev))
        XCTAssertTrue(s.needsRefresh(revision: "caps-future-v4"))
        let a0 = s.completedAnchor(revision: rev)
        s.requestRefresh()
        XCTAssertTrue(s.needsRefresh(revision: rev))
        // A pass that started before the request does not satisfy it.
        s.markCompleted(revision: rev, generation: 0, status: "done")
        XCTAssertTrue(s.needsRefresh(revision: rev))
        s.markCompleted(revision: rev, generation: 1, status: "done")
        XCTAssertFalse(s.needsRefresh(revision: rev))
        XCTAssertNotEqual(s.completedAnchor(revision: rev), a0)
    }

    func testPersistenceRoundTripAndLenientDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CapabilityRefreshState.load(from: url), CapabilityRefreshState())
        CapabilityRefreshState.update(at: url) { $0.requestRefresh() }
        XCTAssertEqual(CapabilityRefreshState.load(from: url).requestedGeneration, 1)
        try Data(#"{"completedRevision":"x"}"#.utf8).write(to: url)
        let s = CapabilityRefreshState.load(from: url)
        XCTAssertEqual(s.completedRevision, "x")
        XCTAssertEqual(s.requestedGeneration, 0)
    }
}

final class RefreshTimeoutTests: XCTestCase {
    func testTimeoutFiresWhenCallbackNeverComes() async {
        do {
            _ = try await withTimeout(seconds: 0.2) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is RefreshTimeout)
        }
    }

    func testValuePassesThrough() async throws {
        let v = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(v, 42)
    }
}
