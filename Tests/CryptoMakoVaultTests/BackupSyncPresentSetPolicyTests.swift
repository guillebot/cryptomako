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
}
