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
}
