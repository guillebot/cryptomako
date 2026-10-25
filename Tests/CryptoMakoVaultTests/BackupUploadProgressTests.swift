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

    // MARK: - Remaining / counter copy (presentation only)

    func testRemainingLabelMidScanIsProvisionalNotFixedTotal() {
        let label = BackupUploadProgress.remainingLabel(
            isRunning: true,
            walkFinished: false,
            filesRemaining: 12_000,
            bytesRemaining: 3_100_000_000_000, // climbs past later settled total
            filesUploaded: 0
        )
        XCTAssertEqual(
            label,
            "Still counting upload candidates — \(12_000.formatted()) files / 3.10 TB so far (rises until scan ends)"
        )
        XCTAssertFalse(label.localizedCaseInsensitiveContains("left to upload"))
        XCTAssertFalse(label.localizedCaseInsensitiveContains("scan complete"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("so far"))
        XCTAssertTrue(label.localizedCaseInsensitiveContains("rises until scan ends"))
    }

    func testRemainingLabelScanCompleteNothingUploadedYet() {
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: true,
                walkFinished: true,
                filesRemaining: 154_226,
                bytesRemaining: 2_580_000_000_000,
                filesUploaded: 0
            ),
            "Scan complete — \(154_226.formatted()) files, 2.58 TB to upload"
        )
    }

    func testRemainingLabelMidUploadDecreases() {
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: true,
                walkFinished: true,
                filesRemaining: 154_219,
                bytesRemaining: 2_580_000_000_000 - 10_400_000,
                filesUploaded: 7
            ),
            "\(154_219.formatted()) files, 2.58 TB left to upload"
        )
    }

    func testRemainingLabelIncidentNumbersCannotReadAsWorkloadGrew() {
        // Mid-scan the provisional tally had climbed past 3 TB; after scan it
        // settled at 2.58 TB. Copy must not reuse "left to upload" / "to upload so far"
        // wording that made those look like the same remaining-work figure.
        let midScanPastSettled = BackupUploadProgress.remainingLabel(
            isRunning: true,
            walkFinished: false,
            filesRemaining: 180_000,
            bytesRemaining: 3_100_000_000_000,
            filesUploaded: 0
        )
        let settled = BackupUploadProgress.remainingLabel(
            isRunning: true,
            walkFinished: true,
            filesRemaining: 154_226,
            bytesRemaining: 2_580_000_000_000,
            filesUploaded: 0
        )
        let midUpload = BackupUploadProgress.remainingLabel(
            isRunning: true,
            walkFinished: true,
            filesRemaining: 154_219,
            bytesRemaining: 2_580_000_000_000 - 10_400_000,
            filesUploaded: 7
        )

        XCTAssertEqual(
            midScanPastSettled,
            "Still counting upload candidates — \(180_000.formatted()) files / 3.10 TB so far (rises until scan ends)"
        )
        XCTAssertEqual(
            settled,
            "Scan complete — \(154_226.formatted()) files, 2.58 TB to upload"
        )
        XCTAssertEqual(
            midUpload,
            "\(154_219.formatted()) files, 2.58 TB left to upload"
        )
        XCTAssertNotEqual(midScanPastSettled, settled)
        XCTAssertFalse(midScanPastSettled.contains("left to upload"))
        XCTAssertFalse(midScanPastSettled.hasPrefix("Scan complete"))

        let counters = BackupUploadProgress.counterBreakdown(
            filesDiscovered: 476_335,
            filesSkipped: 322_109,
            bytesSkipped: 1_510_000_000_000,
            filesToUpload: 154_226,
            bytesToUpload: 2_580_000_000_000,
            filesUploaded: 7,
            bytesUploaded: 10_400_000
        )
        XCTAssertEqual(
            counters,
            "Discovered \(476_335.formatted()) = Skipped \(322_109.formatted()) (1.51 TB) + To upload \(154_226.formatted()) (2.58 TB) · Uploaded \(7.formatted()) (10.4 MB)"
        )
        XCTAssertTrue(counters.contains("="))
        XCTAssertTrue(counters.contains("+"))
        // Equation is explicit: Discovered is not a separate pending queue.
        XCTAssertTrue(counters.hasPrefix("Discovered \(476_335.formatted()) = Skipped"))
    }

    func testRemainingLabelZeroDiscoveredMidScan() {
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: true,
                walkFinished: false,
                filesRemaining: 0,
                bytesRemaining: 0,
                filesUploaded: 0
            ),
            "Still counting upload candidates — \(0.formatted()) files / 0 B so far (rises until scan ends)"
        )
    }

    func testRemainingLabelEverythingSkippedNothingToUpload() {
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: true,
                walkFinished: true,
                filesRemaining: 0,
                bytesRemaining: 0,
                filesUploaded: 0
            ),
            "Scan complete — nothing to upload"
        )
        let counters = BackupUploadProgress.counterBreakdown(
            filesDiscovered: 1_000,
            filesSkipped: 1_000,
            bytesSkipped: 50_000_000,
            filesToUpload: 0,
            bytesToUpload: 0,
            filesUploaded: 0,
            bytesUploaded: 0
        )
        XCTAssertEqual(
            counters,
            "Discovered \(1_000.formatted()) = Skipped \(1_000.formatted()) (50.0 MB) + To upload \(0.formatted()) (0 B) · Uploaded \(0.formatted()) (0 B)"
        )
    }

    func testRemainingLabelIdleFailedOrAbortedIsEmpty() {
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: false,
                walkFinished: false,
                filesRemaining: 12_000,
                bytesRemaining: 3_100_000_000_000,
                filesUploaded: 0
            ),
            ""
        )
        XCTAssertEqual(
            BackupUploadProgress.remainingLabel(
                isRunning: false,
                walkFinished: true,
                filesRemaining: 154_226,
                bytesRemaining: 2_580_000_000_000,
                filesUploaded: 7
            ),
            ""
        )
    }

    func testScanningCaptionIsProvisional() {
        let caption = BackupUploadProgress.scanningCaption
        XCTAssertTrue(caption.localizedCaseInsensitiveContains("provisional"))
        XCTAssertTrue(caption.localizedCaseInsensitiveContains("0%"))
    }
}
