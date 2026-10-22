import CryptoMakoShared
import XCTest

/// The Backup scan must finish and report files/bytes still to upload before any
/// put starts. These tests drive the same `BackupScanPlan` the engine fills during
/// its scan phase, with an "uploader" that records whether it was ever invoked.
final class BackupScanPlanTests: XCTestCase {
    private let medium: Int64 = 256 * 1024
    private let large: Int64 = 32 * 1024 * 1024

    func testScanCompletesAndReportsRemainingBeforeAnyUpload() {
        var plan = BackupScanPlan(mediumThreshold: medium, largeThreshold: large)
        let mtime = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        var uploadsStarted = 0
        // Stand-in for the upload phase. The scan loop below never calls it.
        let startUpload: (BackupPendingUpload) -> Void = { _ in uploadsStarted += 1 }

        var expectedToUpload = BackupScanCount()
        var expectedSkipped = BackupScanCount()
        for i in 0 ..< 50_000 {
            let size = Int64(i % 7) * 100_000 + 1
            let indexed: BackupFileFingerprint? = i.isMultiple(of: 2)
                ? BackupFileFingerprint(size: size, contentModification: mtime)
                : nil
            let action = plan.record(
                relativePath: "dir\(i % 13)/file\(i).bin",
                size: size,
                contentModification: mtime,
                indexed: indexed
            )
            switch action {
            case .skipUnchanged: expectedSkipped.add(bytes: size)
            case .enqueueUpload: expectedToUpload.add(bytes: size)
            }
            // The scan does not start a put even though nothing has uploaded yet.
            XCTAssertEqual(uploadsStarted, 0)
        }
        plan.finish()

        XCTAssertTrue(plan.isFinished)
        XCTAssertEqual(uploadsStarted, 0, "scan completed with zero uploads started")
        XCTAssertEqual(plan.discovered.files, 50_000)
        XCTAssertEqual(plan.skipped, expectedSkipped)
        XCTAssertEqual(plan.toUpload, expectedToUpload)
        XCTAssertEqual(plan.pendingCount, expectedToUpload.files)
        XCTAssertEqual(plan.toUpload.files, 25_000)
        XCTAssertGreaterThan(plan.toUpload.bytes, 0)

        // Only now does the upload phase read the frozen plan.
        for job in plan.small + plan.medium + plan.large { startUpload(job) }
        XCTAssertEqual(uploadsStarted, plan.toUpload.files)
    }

    func testSkippedFilesAreNotRetainedAndTiersPartitionBySize() {
        var plan = BackupScanPlan(mediumThreshold: medium, largeThreshold: large)
        let mtime = Date(timeIntervalSinceReferenceDate: 10)
        let fp = BackupFileFingerprint(size: 5, contentModification: mtime)

        plan.record(relativePath: "unchanged.txt", size: 5, contentModification: mtime, indexed: fp)
        plan.record(relativePath: "a/small.txt", size: 10, contentModification: mtime, indexed: nil)
        plan.record(relativePath: "a/b/medium.bin", size: medium, contentModification: mtime, indexed: nil)
        plan.record(relativePath: "large.iso", size: large + 1, contentModification: mtime, indexed: nil)
        plan.finish()

        XCTAssertEqual(plan.skipped, BackupScanCount(files: 1, bytes: 5))
        XCTAssertEqual(plan.toUpload, BackupScanCount(files: 3, bytes: 10 + medium + large + 1))
        XCTAssertEqual(plan.small.map(\.relativePath), ["a/small.txt"])
        XCTAssertEqual(plan.medium.map(\.relativePath), ["a/b/medium.bin"])
        XCTAssertEqual(plan.large.map(\.relativePath), ["large.iso"])
        // No record of the skipped file anywhere in the plan.
        let retained = (plan.small + plan.medium + plan.large).map(\.relativePath)
        XCTAssertFalse(retained.contains("unchanged.txt"))
        // Only what a put needs: relative path, size, mtime (+ derived parent).
        XCTAssertEqual(plan.medium[0].parentRelativePath, "a/b")
        XCTAssertEqual(plan.large[0].parentRelativePath, "")
        XCTAssertEqual(plan.small[0].size, 10)
        XCTAssertEqual(plan.small[0].contentModification, mtime)
    }

    func testEmptyScanFinishesWithNothingToUpload() {
        var plan = BackupScanPlan(mediumThreshold: medium, largeThreshold: large)
        plan.finish()
        XCTAssertTrue(plan.isFinished)
        XCTAssertEqual(plan.toUpload, BackupScanCount())
        XCTAssertEqual(plan.pendingCount, 0)
    }
}
