import XCTest
@testable import CryptoMakoShared

final class BackupPathOverlapTests: XCTestCase {
    private var scratchRoots: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for root in scratchRoots {
            try? fm.removeItem(at: root)
        }
        scratchRoots.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ name: String = "cm-overlap") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchRoots.append(url)
        return url
    }

    func testResolveReturnsAbsolutePath() throws {
        let dir = makeTempDir()
        let resolved = try BackupPathOverlap.resolve(dir.path)
        XCTAssertFalse(resolved.hasSuffix("/"))
        let expected = dir.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertEqual(expected.lowercased(), resolved.lowercased())
    }

    func testSoftWarnOnAddWhenNestedUnderExisting() throws {
        let root = makeTempDir("cm-ov-root")
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let existing = [BackupSource(path: root.path, vaultFolderName: "Root")]
        let warn = BackupPathOverlap.softWarnOnAdd(existing: existing, candidatePath: child.path)
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn!.localizedCaseInsensitiveContains("overlap"))
    }

    func testSoftWarnOnAddNilWhenDisjoint() throws {
        let a = makeTempDir("cm-ov-a")
        let b = makeTempDir("cm-ov-b")
        let existing = [BackupSource(path: a.path, vaultFolderName: "A")]
        XCTAssertNil(BackupPathOverlap.softWarnOnAdd(existing: existing, candidatePath: b.path))
    }

    func testThrowIfOverlappingWhenParentAndChild() throws {
        let root = makeTempDir("cm-ov-hard")
        let child = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let sources = [
            BackupSource(path: root.path, vaultFolderName: "Root"),
            BackupSource(path: child.path, vaultFolderName: "Child"),
        ]
        XCTAssertThrowsError(try BackupPathOverlap.throwIfOverlapping(sources)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.localizedCaseInsensitiveContains("refused"))
        }
    }

    func testThrowIfOverlappingAllowsSiblings() throws {
        let root = makeTempDir("cm-ov-sib")
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let sources = [
            BackupSource(path: a.path, vaultFolderName: "A"),
            BackupSource(path: b.path, vaultFolderName: "B"),
        ]
        XCTAssertNoThrow(try BackupPathOverlap.throwIfOverlapping(sources))
    }

    func testIsSameOrPrefixCaseInsensitive() {
        XCTAssertTrue(BackupPathOverlap.isSameOrPrefix(
            ancestor: "/Users/Guille/Docs",
            descendant: "/users/guille/docs/nested"
        ))
        XCTAssertFalse(BackupPathOverlap.isSameOrPrefix(
            ancestor: "/Users/guille/docs",
            descendant: "/Users/guille/docs-other"
        ))
    }
}
