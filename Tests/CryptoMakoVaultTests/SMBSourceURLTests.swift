import XCTest
@testable import CryptoMakoShared

final class SMBSourceURLTests: XCTestCase {
    func testNormalizeBasicShare() throws {
        let n = try SMBSourceURL.normalize("smb://files.example/docs")
        XCTAssertEqual(n, "smb://files.example/docs")
    }

    func testNormalizeWithSubpathAndPort() throws {
        let n = try SMBSourceURL.normalize("smb://nas.local:445/backup/photos/")
        XCTAssertEqual(n, "smb://nas.local:445/backup/photos")
    }

    func testNormalizeUNC() throws {
        let n = try SMBSourceURL.normalize(#"\\nas\share\folder"#)
        XCTAssertEqual(n, "smb://nas/share/folder")
    }

    func testRejectMissingShare() {
        XCTAssertThrowsError(try SMBSourceURL.normalize("smb://server-only")) { error in
            XCTAssertEqual(error as? SMBSourceURL.ParseError, .missingShare)
        }
    }

    func testRejectNonSMB() {
        XCTAssertThrowsError(try SMBSourceURL.normalize("https://example/share")) { error in
            XCTAssertEqual(error as? SMBSourceURL.ParseError, .notSMB)
        }
    }

    func testShortLabelAndShareName() throws {
        let n = try SMBSourceURL.normalize("smb://nas/media/films")
        XCTAssertEqual(SMBSourceURL.shareName(from: n), "media")
        XCTAssertEqual(SMBSourceURL.shortLabel(from: n), "nas/media")
    }

    func testBackupSourceCodableDefaultsKindFolder() throws {
        let legacy = """
        {"id":"a","path":"/tmp/x","vaultFolderName":"X","addedAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BackupSource.self, from: legacy)
        XCTAssertEqual(decoded.kind, .folder)
        XCTAssertNil(decoded.smbURL)
        XCTAssertNil(decoded.lastFullSyncAt)
    }

    func testBackupSourceLastFullSyncAtRoundTrip() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var source = BackupSource(id: "s1", path: "/tmp/y", vaultFolderName: "Y")
        source.lastFullSyncAt = stamp
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BackupSource.self, from: data)
        XCTAssertEqual(decoded.lastFullSyncAt, stamp)
        // Encoded JSON must include the key when set.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["lastFullSyncAt"])
    }

    func testBackupSourceSMBRoundTrip() throws {
        let source = BackupSource(
            id: "smb-1",
            path: "/Volumes/share",
            vaultFolderName: "share",
            kind: .smb,
            smbURL: "smb://nas/share",
            smbUsername: "guille",
            bookmarkData: Data([1, 2, 3])
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(BackupSource.self, from: data)
        XCTAssertEqual(decoded, source)
        XCTAssertTrue(decoded.isSMB)
        XCTAssertEqual(decoded.displayLocation, "smb://nas/share")
        XCTAssertEqual(decoded.smbPasswordKeychainAccount, "smb-password-smb-1")
    }

    func testConnectURLIncludesUsernameWithoutPassword() {
        let url = SMBSourceURL.connectURL(normalized: "smb://nas/share/photos", username: "guille")
        XCTAssertEqual(url.scheme, "smb")
        XCTAssertEqual(url.host, "nas")
        XCTAssertEqual(url.user, "guille")
        XCTAssertNil(url.password)
        XCTAssertTrue(url.path.contains("share"))
    }

    func testConnectURLOmitsEmptyUsername() {
        let url = SMBSourceURL.connectURL(normalized: "smb://nas/share", username: "  ")
        XCTAssertNil(url.user)
        XCTAssertEqual(url.absoluteString, "smb://nas/share")
    }
}
