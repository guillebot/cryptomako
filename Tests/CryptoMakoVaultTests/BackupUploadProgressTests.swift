import CryptoMakoShared
import XCTest

final class BackupUploadProgressTests: XCTestCase {
    func testDuringScanNoFractionAndScanningLabel() {
        XCTAssertNil(
            BackupUploadProgress.fraction(
                walkFinished: false,
                bytesUploaded: 0,
                bytesToUpload: 1_000
            )
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: false,
                bytesUploaded: 0,
                bytesToUpload: 1_000
            ),
            "Scanning"
        )
    }

    func testAfterScanZeroUntilFirstUpload() {
        XCTAssertEqual(
            BackupUploadProgress.fraction(
                walkFinished: true,
                bytesUploaded: 0,
                bytesToUpload: 10_000
            ),
            0
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: 0,
                bytesToUpload: 10_000
            ),
            "0%"
        )
    }

    func testSkippedBytesDoNotCountTowardUploadPercent() {
        // 36% of the tree already in the vault must not open the bar at 36%.
        // Only completed puts over the to-upload set move the percent.
        let toUpload: Int64 = 6_400
        let uploaded: Int64 = 640
        let frac = BackupUploadProgress.fraction(
            walkFinished: true,
            bytesUploaded: uploaded,
            bytesToUpload: toUpload
        )
        XCTAssertEqual(frac!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: uploaded,
                bytesToUpload: toUpload
            ),
            "10%"
        )
    }

    func testEmptyToUploadIsComplete() {
        XCTAssertEqual(
            BackupUploadProgress.fraction(
                walkFinished: true,
                bytesUploaded: 0,
                bytesToUpload: 0
            ),
            1
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: 0,
                bytesToUpload: 0
            ),
            "100%"
        )
    }

    func testFullUploadIs100AndJobFinishedOverride() {
        XCTAssertEqual(
            BackupUploadProgress.fraction(
                walkFinished: true,
                bytesUploaded: 5_000,
                bytesToUpload: 5_000
            ),
            1
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: 5_000,
                bytesToUpload: 5_000
            ),
            "100%"
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: false,
                bytesUploaded: 0,
                bytesToUpload: 0,
                jobFinished: true
            ),
            "100%"
        )
    }

    func testIntegerFloorMatchesStuckLegacyBehaviorCase() {
        // Tiny progress over a huge to-upload still moves off 0 once a full percent.
        let toUpload: Int64 = 4_000_000_000_000 // 4 TB
        let uploaded: Int64 = 40_000_000_000 // 40 GB → 1%
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: uploaded,
                bytesToUpload: toUpload
            ),
            "1%"
        )
        XCTAssertEqual(
            BackupUploadProgress.percentLabel(
                walkFinished: true,
                bytesUploaded: uploaded / 2,
                bytesToUpload: toUpload
            ),
            "0%"
        )
    }
}
