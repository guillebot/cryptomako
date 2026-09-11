import CryptomatorCryptoLib
import CryptoMakoS3
import XCTest

@testable import CryptoMakoVault

final class VaultTests: XCTestCase {
    func testDirIdPathHasTwoCharShard() throws {
        let masterkey = try Masterkey.createNew()
        let cryptor = Cryptor(masterkey: masterkey, scheme: .sivGcm)
        let hash = try cryptor.encryptDirId(Data()).replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(hash.count, 32)
        let prefix = try DirLayout.ciphertextDirectoryPrefix(prefix: "family/", cryptor: cryptor, dirId: "")
        XCTAssertTrue(prefix.hasPrefix("family/d/"))
        XCTAssertTrue(prefix.hasSuffix("/"))
        let parts = prefix.split(separator: "/")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[1], "d")
        XCTAssertEqual(parts[2].count, 2)
        XCTAssertEqual(parts[3].count, 30)
    }

    func testFileNameRoundTrip() throws {
        let masterkey = try Masterkey.createNew()
        let cryptor = Cryptor(masterkey: masterkey, scheme: .sivGcm)
        let dirId = Data("parent".utf8)
        let cipher = try cryptor.encryptFileName("hello.txt", dirId: dirId)
        let clear = try cryptor.decryptFileName(cipher, dirId: dirId)
        XCTAssertEqual(clear, "hello.txt")
    }

    func testJWTVerifyRoundTrip() throws {
        let masterkey = try Masterkey.createNew()
        let token = try VaultJWT.sign(
            header: [
                "alg": "HS256",
                "typ": "JWT",
                "kid": "masterkeyfile:masterkey.cryptomator",
            ],
            payload: [
                "format": 8,
                "shorteningThreshold": 220,
                "cipherCombo": "SIV_GCM",
                "jti": "00000000-0000-0000-0000-000000000001",
            ],
            rawKey: masterkey.rawKey
        )
        let payload = try VaultJWT.verify(token: token, rawKey: masterkey.rawKey)
        XCTAssertEqual(payload.format, 8)
        XCTAssertEqual(payload.cipherCombo, "SIV_GCM")
    }

    func testUnlockAndListFromMemoryStore() async throws {
        let passphrase = "test"
        let masterkey = try Masterkey.createNew()
        let masterJSON = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: 999,
            passphrase: passphrase,
            scryptCostParam: 16
        )
        let token = try VaultJWT.sign(
            header: [
                "alg": "HS256",
                "typ": "JWT",
                "kid": "masterkeyfile:masterkey.cryptomator",
            ],
            payload: [
                "format": 8,
                "shorteningThreshold": 220,
                "cipherCombo": "SIV_GCM",
                "jti": "11111111-1111-1111-1111-111111111111",
            ],
            rawKey: masterkey.rawKey
        )
        let cryptor = Cryptor(masterkey: masterkey, scheme: .sivGcm)
        let dirPrefix = try DirLayout.ciphertextDirectoryPrefix(prefix: "family/", cryptor: cryptor, dirId: "")
        let fileCipher = try cryptor.encryptFileName("hello.txt", dirId: Data())
        let fileKey = dirPrefix + fileCipher + ".c9r"

        let clearURL = FileManager.default.temporaryDirectory.appendingPathComponent("cm-hello.txt")
        let cipherURL = FileManager.default.temporaryDirectory.appendingPathComponent("cm-hello.c9r")
        try Data("hello cryptomako\n".utf8).write(to: clearURL)
        try cryptor.encryptContent(from: clearURL, to: cipherURL)
        let cipherData = try Data(contentsOf: cipherURL)

        var objects: [String: Data] = [
            "family/vault.cryptomator": Data(token.utf8),
            "family/masterkey.cryptomator": masterJSON,
            fileKey: cipherData,
        ]

        let notesId = UUID().uuidString
        let notesCipher = try cryptor.encryptFileName("notes", dirId: Data())
        let notesPrefix = dirPrefix + notesCipher + ".c9r/"
        objects[notesPrefix + "dir.c9r"] = Data(notesId.utf8)

        let notesDirPrefix = try DirLayout.ciphertextDirectoryPrefix(
            prefix: "family/",
            cryptor: cryptor,
            dirId: notesId
        )
        let todoCipher = try cryptor.encryptFileName("todo.md", dirId: Data(notesId.utf8))
        let todoClear = FileManager.default.temporaryDirectory.appendingPathComponent("cm-todo.md")
        let todoCipherURL = FileManager.default.temporaryDirectory.appendingPathComponent("cm-todo.c9r")
        try Data("buy milk\n".utf8).write(to: todoClear)
        try cryptor.encryptContent(from: todoClear, to: todoCipherURL)
        objects[notesDirPrefix + todoCipher + ".c9r"] = try Data(contentsOf: todoCipherURL)

        let store = InMemoryStore(objects: objects)
        let location = VaultLocation(
            endpoint: URL(string: "http://127.0.0.1:9000")!,
            region: "us-east-1",
            bucket: "cryptomako-poc",
            prefix: "family/",
            accessKey: "cryptomako"
        )
        let session = try await VaultSession.unlock(location: location, passphrase: passphrase, store: store)
        XCTAssertEqual(session.config.format, 8)

        let root = try await session.list(dirId: "")
        XCTAssertEqual(root.map(\.cleartextName).sorted(), ["hello.txt", "notes"])

        let hello = try await session.cat(cleartextPath: "/hello.txt")
        XCTAssertEqual(String(data: hello, encoding: .utf8), "hello cryptomako\n")

        let todo = try await session.cat(cleartextPath: "/notes/todo.md")
        XCTAssertEqual(String(data: todo, encoding: .utf8), "buy milk\n")
    }

    func testWrongPasswordFailsClosed() async throws {
        let masterkey = try Masterkey.createNew()
        let masterJSON = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: 999,
            passphrase: "right",
            scryptCostParam: 16
        )
        let token = try VaultJWT.sign(
            header: ["alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"],
            payload: ["format": 8, "cipherCombo": "SIV_GCM", "shorteningThreshold": 220],
            rawKey: masterkey.rawKey
        )
        let store = InMemoryStore(objects: [
            "vault.cryptomator": Data(token.utf8),
            "masterkey.cryptomator": masterJSON,
        ])
        let location = VaultLocation(
            endpoint: URL(string: "http://127.0.0.1:9000")!,
            region: "us-east-1",
            bucket: "b",
            prefix: "",
            accessKey: "k"
        )
        do {
            _ = try await VaultSession.unlock(location: location, passphrase: "wrong", store: store)
            XCTFail("expected unlock failure")
        } catch VaultError.unlockFailed {
            // expected
        }
    }

    func testFixtureVaultUnlocksAndLists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let passphrase = "fixture-pass"
        try VaultFixture.create(at: root, passphrase: passphrase)
        let store = DirectoryObjectStore(root: root)
        let location = VaultLocation(
            endpoint: URL(string: "http://127.0.0.1:9000")!,
            region: "us-east-1",
            bucket: "b",
            prefix: "",
            accessKey: "k"
        )
        let session = try await VaultSession.unlock(location: location, passphrase: passphrase, store: store)
        XCTAssertEqual(session.config.format, 8)
        let names = try await session.list(dirId: "").map(\.cleartextName)
        XCTAssertTrue(names.contains("hello.txt"))
        XCTAssertTrue(names.contains("notes"))
        XCTAssertTrue(names.contains("bin"))
        XCTAssertTrue(names.contains(VaultFixture.cafeName))
        XCTAssertTrue(names.contains(VaultFixture.longName))
        let hello = try await session.cat(cleartextPath: "/hello.txt")
        XCTAssertEqual(hello, VaultFixture.helloContents)
        let todo = try await session.cat(cleartextPath: "/notes/todo.md")
        XCTAssertEqual(todo, VaultFixture.todoContents)
        let png = try await session.cat(cleartextPath: "/bin/tiny.png")
        XCTAssertEqual(png, VaultFixture.tinyPNG)
        let long = try await session.cat(cleartextPath: "/\(VaultFixture.longName)")
        XCTAssertEqual(long, VaultFixture.longContents)

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("cm-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let helloNode = try await session.resolveFile(cleartextPath: "/hello.txt")
        try await session.fetch(node: helloNode, to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), VaultFixture.helloContents)

        let recursive = try await session.listRecursive(at: "/")
        let listing = recursive.map { path, node in
            path + (node.kind == .directory ? "/" : "")
        }.joined(separator: "\n") + "\n"
        let expectedURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/expected-ls.txt")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        XCTAssertEqual(
            listing.trimmingCharacters(in: .newlines),
            expected.trimmingCharacters(in: .newlines)
        )

        let longNode = try await session.resolveFile(cleartextPath: "/\(VaultFixture.longName)")
        XCTAssertNotNil(longNode.size)
        XCTAssertGreaterThan(longNode.size ?? 0, 0)
        XCTAssertEqual(ItemIdentifier.of(longNode).rawValue.hasPrefix("f:"), true)

        let index = DirectoryIndex(session: session)
        let notes = try await session.list(dirId: "").first { $0.cleartextName == "notes" }
        let notesId = try XCTUnwrap(notes?.dirId)
        let info = try await index.directoryInfo(dirId: notesId)
        XCTAssertEqual(info?.name, "notes")
        XCTAssertEqual(info?.parentDirId, "")
        let notesChildren = try await session.list(dirId: notesId)
        let todoCipher = try XCTUnwrap(notesChildren.first { $0.cleartextName == "todo.md" }?.cipherName)
        let todoNode = try await index.file(parentDirId: notesId, cipherName: todoCipher)
        XCTAssertEqual(todoNode?.cleartextName, "todo.md")
    }
}
