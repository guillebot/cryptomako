import XCTest
@testable import CryptoMakoShared

final class SMBVolumeNameMatchTests: XCTestCase {
    func testExactShareNameMatches() {
        XCTAssertTrue(SMBVolumeNameMatch.volumeLeaf("photos", matchesShare: "photos"))
        XCTAssertTrue(SMBVolumeNameMatch.volumeLeaf("Photos", matchesShare: "photos"))
    }

    func testDigitSuffixDuplicateMountMatches() {
        XCTAssertTrue(SMBVolumeNameMatch.volumeLeaf("photos-1", matchesShare: "photos"))
        XCTAssertTrue(SMBVolumeNameMatch.volumeLeaf("photos-2", matchesShare: "photos"))
        XCTAssertTrue(SMBVolumeNameMatch.volumeLeaf("PHOTOS-12", matchesShare: "photos"))
    }

    func testNonDigitSuffixDoesNotMatch() {
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("photos-backup", matchesShare: "photos"))
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("photos-bak", matchesShare: "photos"))
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("photos-1a", matchesShare: "photos"))
    }

    func testUnrelatedLeafDoesNotMatch() {
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("documents", matchesShare: "photos"))
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("photos2", matchesShare: "photos"))
        XCTAssertFalse(SMBVolumeNameMatch.volumeLeaf("photos-", matchesShare: "photos"))
    }
}
