import CryptoMakoShared
import XCTest

/// Proves the walk skip/enqueue gate never needs a vault LIST or reachability probe.
/// Call sites must not add remote work on `.skipUnchanged` or on cold-index enqueue.
final class BackupWalkSkipPolicyTests: XCTestCase {
    func testMatchingFingerprintSkipsWithoutRemote() {
        let mtime = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let indexed = BackupFileFingerprint(size: 4_096, contentModification: mtime)
        let action = BackupWalkSkipPolicy.action(
            indexed: indexed,
            size: 4_096,
            contentModification: mtime
        )
        XCTAssertEqual(action, .skipUnchanged)
    }

    func testColdIndexEnqueuesWithoutVaultList() {
        // Empty BackupSyncState → every file is enqueue, never bootstrap LIST.
        let action = BackupWalkSkipPolicy.action(
            indexed: nil,
            size: 1024,
            contentModification: Date()
        )
        XCTAssertEqual(action, .enqueueUpload)
    }

    func testStaleSizeEnqueues() {
        let mtime = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let indexed = BackupFileFingerprint(size: 100, contentModification: mtime)
        let action = BackupWalkSkipPolicy.action(
            indexed: indexed,
            size: 200,
            contentModification: mtime
        )
        XCTAssertEqual(action, .enqueueUpload)
    }

    func testStaleMtimeEnqueues() {
        let indexed = BackupFileFingerprint(
            size: 100,
            contentModification: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let action = BackupWalkSkipPolicy.action(
            indexed: indexed,
            size: 100,
            contentModification: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        XCTAssertEqual(action, .enqueueUpload)
    }

    func testSkipPathDoesNotRequireProbeOrListHooks() {
        // Regression guard: the policy API surface has no session / probe parameters.
        // If someone adds vault or reachability args here, this mirror of the signature fails to compile.
        let decide: (BackupFileFingerprint?, Int64, Date) -> BackupWalkFileAction =
            BackupWalkSkipPolicy.action
        let fp = BackupFileFingerprint(size: 1, contentModification: .distantPast)
        XCTAssertEqual(decide(fp, 1, .distantPast), .skipUnchanged)
        XCTAssertEqual(decide(nil, 1, .distantPast), .enqueueUpload)
    }

    /// A skip-only pass over an already-indexed tree must not probe, list the vault,
    /// or persist the fingerprint map — including once per N files.
    func testSkipOnlyEnumerationDoesNotProbeListOrSave() {
        let mtime = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let indexed = BackupFileFingerprint(size: 4_096, contentModification: mtime)
        var probes = 0
        var lists = 0
        var saves = 0
        var skipped = 0
        for _ in 0 ..< 5_000 {
            let step = BackupWalkSkipPolicy.step(
                indexed: indexed,
                size: indexed.size,
                contentModification: mtime
            )
            XCTAssertEqual(step.action, .skipUnchanged)
            if step.probe { probes += 1 }
            if step.listVault { lists += 1 }
            if step.saveIndex { saves += 1 }
            if step.action == .skipUnchanged { skipped += 1 }
        }
        XCTAssertEqual(skipped, 5_000)
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(lists, 0)
        XCTAssertEqual(saves, 0)
    }

    func testEnqueueStepDoesNotProbeListOrSave() {
        let step = BackupWalkSkipPolicy.step(
            indexed: nil,
            size: 8,
            contentModification: Date(timeIntervalSinceReferenceDate: 50)
        )
        XCTAssertEqual(step.action, .enqueueUpload)
        XCTAssertFalse(step.probe)
        XCTAssertFalse(step.listVault)
        XCTAssertFalse(step.saveIndex)
    }
}
