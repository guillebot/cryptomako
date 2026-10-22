import XCTest
@testable import CryptoMakoShared

final class BackupRelativePathTests: XCTestCase {
    func testRelativePathUnderRoot() throws {
        XCTAssertEqual(
            try BackupRelativePath.make(filePath: "/data/src/a/b.txt", rootPath: "/data/src"),
            "a/b.txt"
        )
        XCTAssertEqual(
            try BackupRelativePath.make(filePath: "/data/src", rootPath: "/data/src"),
            ""
        )
    }

    func testFailsWhenNotUnderRoot() {
        XCTAssertThrowsError(
            try BackupRelativePath.make(filePath: "/other/a.txt", rootPath: "/data/src")
        ) { error in
            guard case BackupRelativePath.Error.notUnderRoot = error else {
                return XCTFail("expected notUnderRoot, got \(error)")
            }
        }
    }

    func testFailsOnStringPrefixSibling() {
        // `/data/src` must not match `/data/src2/...`
        XCTAssertThrowsError(
            try BackupRelativePath.make(filePath: "/data/src2/a.txt", rootPath: "/data/src")
        ) { error in
            guard case BackupRelativePath.Error.notUnderRoot = error else {
                return XCTFail("expected notUnderRoot, got \(error)")
            }
        }
    }
}
