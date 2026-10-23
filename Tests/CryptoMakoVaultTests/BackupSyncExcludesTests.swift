import XCTest
@testable import CryptoMakoShared

final class BackupSyncExcludesTests: XCTestCase {
    func testDefaultSkipsNodeModulesAndGitTrees() {
        let excludes = BackupSyncExcludes.default
        XCTAssertTrue(excludes.shouldSkipDirectory(named: "node_modules"))
        XCTAssertTrue(excludes.shouldSkipDirectory(named: ".git"))
        XCTAssertTrue(excludes.shouldSkipRelativePath("proj/node_modules/pkg/index.js"))
        XCTAssertFalse(excludes.shouldSkipRelativePath("proj/src/index.js"))
    }

    func testFileNameAndExtensionFilters() {
        let excludes = BackupSyncExcludes.default
        XCTAssertTrue(excludes.shouldSkipFile(named: ".DS_Store"))
        XCTAssertTrue(excludes.shouldSkipFile(named: "cache.pyc"))
        XCTAssertTrue(excludes.shouldSkipFile(named: "Foo.SWIFTINTERFACE"))
        XCTAssertFalse(excludes.shouldSkipFile(named: "notes.txt"))
        // Extension match requires a real extension segment.
        XCTAssertFalse(excludes.shouldSkipFile(named: "pyc"))
    }

    func testRelativePathSkipsWhenAnyComponentIsExcludedFile() {
        let excludes = BackupSyncExcludes.default
        XCTAssertTrue(excludes.shouldSkipRelativePath("album/.DS_Store"))
        XCTAssertTrue(excludes.shouldSkipRelativePath("build/DerivedData/ModuleCache.noindex/x"))
    }
}
