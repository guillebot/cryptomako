import XCTest
@testable import CryptoMakoShared

final class MountedSharePathGuardTests: XCTestCase {
    func testAcceptsPathUnderVolume() {
        XCTAssertTrue(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: "/Volumes/photos/family/2024",
                volumeRootPath: "/Volumes/photos",
                resolveSymlinks: false
            )
        )
        XCTAssertTrue(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: "/Volumes/photos",
                volumeRootPath: "/Volumes/photos",
                resolveSymlinks: false
            )
        )
    }

    func testRejectsPathOutsideVolume() {
        XCTAssertFalse(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: "/Users/guille/Pictures",
                volumeRootPath: "/Volumes/photos",
                resolveSymlinks: false
            )
        )
        XCTAssertFalse(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: "/Volumes/photos-backup",
                volumeRootPath: "/Volumes/photos",
                resolveSymlinks: false
            )
        )
    }

    func testRejectsSymlinkThatEscapesVolume() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cm-share-guard-\(UUID().uuidString)")
        let volume = base.appendingPathComponent("Volumes/photos", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let link = volume.appendingPathComponent("escape", isDirectory: false)
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertFalse(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: link.path,
                volumeRootPath: volume.path,
                resolveSymlinks: true
            )
        )
        XCTAssertTrue(
            MountedSharePathGuard.isInsideMountedVolume(
                candidatePath: volume.appendingPathComponent("subdir").path,
                volumeRootPath: volume.path,
                resolveSymlinks: false
            )
        )
    }
}
