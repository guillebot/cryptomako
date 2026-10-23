import XCTest
@testable import CryptoMakoShared

final class BackupSyncPresentSetPolicyTests: XCTestCase {
    func testExcludedPathStaysInPruneAllowSetAndIsNotUploadEligible() {
        let disposition = BackupSyncPresentSetPolicy.disposition(isHidden: false, isExcluded: true)
        XCTAssertEqual(disposition, .presentDoNotUpload)
        XCTAssertTrue(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: true, pathPresentOnDisk: true)
        )
    }

    func testHiddenPathStaysInPruneAllowSetAndIsNotUploadEligible() {
        let disposition = BackupSyncPresentSetPolicy.disposition(isHidden: true, isExcluded: false)
        XCTAssertEqual(disposition, .presentDoNotUpload)
        XCTAssertTrue(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: true, pathPresentOnDisk: true)
        )
    }

    func testEligiblePathIsPresentAndUploadEligible() {
        let disposition = BackupSyncPresentSetPolicy.disposition(isHidden: false, isExcluded: false)
        XCTAssertEqual(disposition, .presentUploadEligible)
        XCTAssertTrue(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: true, pathPresentOnDisk: true)
        )
    }

    func testAbsentPathIsNotInPruneAllowSet() {
        XCTAssertFalse(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: true, pathPresentOnDisk: false)
        )
    }

    func testBackupModeDoesNotRetainPresentSet() {
        XCTAssertFalse(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: false, pathPresentOnDisk: true)
        )
    }

    /// 1.0.9 H1: Sync must keep enumerating hidden files so prune never deletes
    /// vault ciphertext for a path that still exists on disk (even if not uploaded).
    func testSyncModeEnumeratorDoesNotSkipHiddenFiles() {
        XCTAssertFalse(BackupScanEnumeratorPolicy.skipsHiddenFiles(isSyncMode: true))
        let options = BackupScanEnumeratorPolicy.directoryEnumerationOptions(isSyncMode: true)
        XCTAssertFalse(options.contains(.skipsHiddenFiles))
        XCTAssertTrue(options.contains(.skipsPackageDescendants))
        // Characterization: a present hidden path remains in the prune allow-set.
        XCTAssertTrue(
            BackupSyncPresentSetPolicy.retainInPruneAllowSet(isSyncMode: true, pathPresentOnDisk: true)
        )
        XCTAssertEqual(
            BackupSyncPresentSetPolicy.disposition(isHidden: true, isExcluded: false),
            .presentDoNotUpload
        )
    }

    /// Backup has no prune allow-set; skip hidden at the enumerator to avoid
    /// SMB attribute fetches for .DS_Store / AppleDouble that would be discarded.
    func testBackupModeEnumeratorSkipsHiddenFiles() {
        XCTAssertTrue(BackupScanEnumeratorPolicy.skipsHiddenFiles(isSyncMode: false))
        let options = BackupScanEnumeratorPolicy.directoryEnumerationOptions(isSyncMode: false)
        XCTAssertTrue(options.contains(.skipsHiddenFiles))
        XCTAssertTrue(options.contains(.skipsPackageDescendants))
    }
}
