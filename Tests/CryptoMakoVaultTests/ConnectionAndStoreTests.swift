import CryptoMakoShared
@testable import CryptoMakoS3
import XCTest

final class ConnectionConfigLoaderTests: XCTestCase {
    func testLocalModeNeedsPasswordOnly() throws {
        let config = try ConnectionConfigLoader.resolve(
            ConnectionRequest(localPath: "/tmp/vault"),
            environment: ["CRYPTOMAKO_PASSWORD": "secret"]
        )
        XCTAssertTrue(config.isLocal)
        XCTAssertEqual(config.localRoot?.path, "/tmp/vault")
        XCTAssertEqual(config.passphrase, "secret")
        XCTAssertEqual(config.secretKey, "")
    }

    func testS3ModeRequiresEndpointBucketAccessKeyAndSecret() {
        XCTAssertThrowsError(
            try ConnectionConfigLoader.resolve(
                ConnectionRequest(endpoint: "http://127.0.0.1:9000", bucket: "b", accessKey: "k"),
                environment: ["CRYPTOMAKO_PASSWORD": "pass"]
            )
        ) { error in
            XCTAssertEqual(error as? ConnectionConfigError, .missing("env CRYPTOMAKO_SECRET_KEY"))
        }
    }

    func testMergesConfigFileWithCLIOverrides() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("poc.json")
        let json = """
        {"endpoint":"http://file:9000","region":"eu-west-1","bucket":"from-file","prefix":"p/","accessKey":"file-key"}
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let config = try ConnectionConfigLoader.resolve(
            ConnectionRequest(
                configURL: configURL,
                bucket: "override-bucket"
            ),
            environment: [
                "CRYPTOMAKO_PASSWORD": "pass",
                "CRYPTOMAKO_SECRET_KEY": "secret",
            ]
        )
        XCTAssertEqual(config.endpoint.absoluteString, "http://file:9000")
        XCTAssertEqual(config.region, "eu-west-1")
        XCTAssertEqual(config.bucket, "override-bucket")
        XCTAssertEqual(config.prefix, "p/")
        XCTAssertEqual(config.accessKey, "file-key")
        XCTAssertEqual(config.secretKey, "secret")
        XCTAssertTrue(config.pathStyle)
    }

    func testVirtualHostedDisablesPathStyle() throws {
        let config = try ConnectionConfigLoader.resolve(
            ConnectionRequest(
                endpoint: "http://127.0.0.1:9000",
                bucket: "b",
                accessKey: "k",
                virtualHosted: true
            ),
            environment: [
                "CRYPTOMAKO_PASSWORD": "pass",
                "CRYPTOMAKO_SECRET_KEY": "secret",
            ]
        )
        XCTAssertFalse(config.pathStyle)
    }
}

final class DirectoryObjectStoreTests: XCTestCase {
    func testRejectsPathTraversalKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-traversal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("safe.txt"))
        let store = DirectoryObjectStore(root: root)

        do {
            _ = try await store.getObject(key: "../safe.txt")
            XCTFail("expected transport error")
        } catch ObjectStoreError.transport(let message) {
            XCTAssertEqual(message, "invalid object key")
        }

        do {
            _ = try await store.getObject(key: "/etc/passwd")
            XCTFail("expected transport error")
        } catch ObjectStoreError.transport {
            // expected
        }
    }

    func testListsImmediateChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let store = DirectoryObjectStore(root: root)
        let listing = try await store.listImmediate(prefix: "")
        XCTAssertEqual(listing.objects.map(\.key).sorted(), ["a.txt"])
        XCTAssertEqual(listing.commonPrefixes, ["subdir/"])
    }
}

final class SafePathTests: XCTestCase {
    func testResolveAllowsNestedKeys() throws {
        let root = URL(fileURLWithPath: "/tmp/vault")
        let url = try SafePath.resolve(root: root, key: "d/ab/file.c9r")
        XCTAssertTrue(url.path.hasSuffix("d/ab/file.c9r"))
    }
}
