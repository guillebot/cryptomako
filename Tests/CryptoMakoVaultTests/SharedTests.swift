import XCTest

@testable import CryptoMakoShared
@testable import CryptoMakoVault

final class ItemIdentifierTests: XCTestCase {
    func testRootAndDirectory() {
        XCTAssertEqual(ItemIdentifier(rawValue: "d:"), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: ""), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: "root"), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: "d:abc")?.rawValue, "d:abc")
        if case .directory(let id) = ItemIdentifier(rawValue: "d:abc") {
            XCTAssertEqual(id, "abc")
        } else {
            XCTFail("expected directory")
        }
    }

    func testFileSplitsOnFirstSlash() {
        let parsed = ItemIdentifier(rawValue: "f:parent-id/name.c9r")
        guard case .file(let parent, let cipher) = parsed else {
            return XCTFail("expected file")
        }
        XCTAssertEqual(parent, "parent-id")
        XCTAssertEqual(cipher, "name.c9r")
    }

    func testFileRejectsMissingSlash() {
        XCTAssertNil(ItemIdentifier(rawValue: "f:noslash"))
        XCTAssertNil(ItemIdentifier(rawValue: "x:nope"))
    }
}

final class VaultSettingsTests: XCTestCase {
    func testDecodesLegacyPocJSONWithoutLocalPath() throws {
        let json = """
        {"endpoint":"http://example:9000","region":"us-east-1","bucket":"b","prefix":"p/","accessKey":"k"}
        """
        let settings = try JSONDecoder().decode(VaultSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.bucket, "b")
        XCTAssertEqual(settings.localVaultPath, "")
        XCTAssertFalse(settings.isLocal)
        XCTAssertEqual(settings.storageMode, .s3)
        XCTAssertTrue(settings.isComplete)
    }

    func testLocalPathIsCompleteWithoutS3() {
        let settings = VaultSettings(storageMode: .local, localVaultPath: "/tmp/vault")
        XCTAssertTrue(settings.isLocal)
        XCTAssertTrue(settings.isComplete)
    }

    func testLegacyLocalPathImpliesLocalMode() throws {
        let json = """
        {"endpoint":"http://example:9000","region":"us-east-1","bucket":"b","prefix":"","accessKey":"k","localVaultPath":"/tmp/v"}
        """
        let settings = try JSONDecoder().decode(VaultSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.storageMode, .local)
        XCTAssertTrue(settings.isLocal)
    }

    func testPrefixNormalizationAndPreview() {
        var settings = VaultSettings(storageMode: .s3, bucket: "sch-backup", prefix: "cryptomako-poc")
        XCTAssertEqual(settings.normalizedPrefix, "cryptomako-poc/")
        XCTAssertEqual(settings.vaultObjectKeyPreview, "sch-backup/cryptomako-poc/vault.cryptomator")
        settings.normalizeForSave()
        XCTAssertEqual(settings.prefix, "cryptomako-poc/")
    }
}

final class CredentialStoreTests: XCTestCase {
    func testLocalSaveReadDelete() throws {
        let account = "test-\(UUID().uuidString)"
        defer { CredentialStore.delete(account: account, useAccessGroup: false) }
        try CredentialStore.save("secret-value", account: account, useAccessGroup: false)
        XCTAssertEqual(try CredentialStore.read(account: account, useAccessGroup: false), "secret-value")
        CredentialStore.delete(account: account, useAccessGroup: false)
        XCTAssertThrowsError(try CredentialStore.read(account: account, useAccessGroup: false))
    }
}
