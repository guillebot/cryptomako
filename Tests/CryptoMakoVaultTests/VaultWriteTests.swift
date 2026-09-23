import CryptoMakoS3
import CryptoMakoVault
import XCTest

final class VaultWriteTests: XCTestCase {
    func testCreateFileAndDirectoryThenList() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let passphrase = "test-passphrase-writes"
        try VaultFixture.create(at: root, passphrase: passphrase)
        let store = DirectoryObjectStore(root: root)
        let session = try await VaultSession.unlock(
            location: .local(prefix: ""),
            passphrase: passphrase,
            store: store
        )

        let folder = try await session.createDirectory(parentDirId: "", cleartextName: "uploads")
        XCTAssertEqual(folder.kind, .directory)
        XCTAssertNotNil(folder.dirId)

        let clear = root.appendingPathComponent("payload.txt")
        try Data("remote-only payload\n".utf8).write(to: clear)
        let file = try await session.createOrOverwriteFile(
            parentDirId: folder.dirId!,
            cleartextName: "payload.txt",
            contentsURL: clear
        )
        XCTAssertEqual(file.kind, .file)

        let rootNames = try await session.list(dirId: "").map(\.cleartextName)
        XCTAssertTrue(rootNames.contains("uploads"))

        let childNames = try await session.list(dirId: folder.dirId!).map(\.cleartextName)
        XCTAssertEqual(childNames, ["payload.txt"])

        // Overwrite must replace remote ciphertext (same cleartext name).
        try Data("updated\n".utf8).write(to: clear)
        _ = try await session.createOrOverwriteFile(
            parentDirId: folder.dirId!,
            cleartextName: "payload.txt",
            contentsURL: clear
        )
        let data = try await session.cat(cleartextPath: "/uploads/payload.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "updated\n")
    }

    func testRecursiveDeleteDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-del-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let passphrase = "test-passphrase-delete"
        try VaultFixture.create(at: root, passphrase: passphrase)
        let store = DirectoryObjectStore(root: root)
        let session = try await VaultSession.unlock(
            location: .local(prefix: ""),
            passphrase: passphrase,
            store: store
        )

        let folder = try await session.createDirectory(parentDirId: "", cleartextName: "todelete")
        let clear = root.appendingPathComponent("gone.txt")
        try Data("x\n".utf8).write(to: clear)
        _ = try await session.createOrOverwriteFile(
            parentDirId: folder.dirId!,
            cleartextName: "gone.txt",
            contentsURL: clear
        )

        try await session.deleteDirectory(node: folder, recursive: true)
        let names = try await session.list(dirId: "").map(\.cleartextName)
        XCTAssertFalse(names.contains("todelete"))
    }
}
