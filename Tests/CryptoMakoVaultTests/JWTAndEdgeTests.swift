import CryptomatorCryptoLib
import CryptoMakoS3
import XCTest

@testable import CryptoMakoVault

final class JWTTests: XCTestCase {
    func testRejectsMalformedToken() {
        XCTAssertThrowsError(try VaultJWT.verify(token: "not-a-jwt", rawKey: [0x00]))
        XCTAssertThrowsError(try VaultJWT.verify(token: "a.b", rawKey: [0x00]))
    }

    func testRejectsTamperedPayload() throws {
        let masterkey = try Masterkey.createNew()
        let token = try VaultJWT.sign(
            header: ["alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"],
            payload: ["format": 8, "cipherCombo": "SIV_GCM", "shorteningThreshold": 220],
            rawKey: masterkey.rawKey
        )
        var parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        parts[1] = "AAAA"
        let tampered = parts.joined(separator: ".")
        XCTAssertThrowsError(try VaultJWT.verify(token: tampered, rawKey: masterkey.rawKey))
    }

    func testRejectsUnsupportedAlgorithm() throws {
        let masterkey = try Masterkey.createNew()
        XCTAssertThrowsError(
            try VaultJWT.sign(
                header: ["alg": "RS256", "kid": "masterkeyfile:masterkey.cryptomator"],
                payload: ["format": 8, "cipherCombo": "SIV_GCM", "shorteningThreshold": 220],
                rawKey: masterkey.rawKey
            )
        ) { error in
            guard case VaultError.invalidJWT = error else {
                return XCTFail("expected invalidJWT, got \(error)")
            }
        }
    }

    func testBase64URLRoundTrip() throws {
        let payload = Data("{\"format\":8}".utf8)
        let encoded = VaultJWT.base64URLEncode(payload)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        let decoded = try VaultJWT.base64URLDecode(encoded)
        XCTAssertEqual(decoded, payload)
    }

    func testInvalidJWTDoesNotLeakDetails() {
        let error = VaultError.invalidJWT
        XCTAssertEqual(error.errorDescription, "unlock failed")
    }
}

final class VaultSessionEdgeTests: XCTestCase {
    func testMissingVaultConfig() async throws {
        let store = InMemoryStore(objects: [:])
        let location = VaultLocation.local()
        do {
            _ = try await VaultSession.unlock(location: location, passphrase: "x", store: store)
            XCTFail("expected missingVaultConfig")
        } catch VaultError.missingVaultConfig {
            // expected
        }
    }

    func testUnsupportedFormatAfterUnlock() async throws {
        let masterkey = try Masterkey.createNew()
        let masterJSON = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: 999,
            passphrase: "pass",
            scryptCostParam: 16
        )
        let token = try VaultJWT.sign(
            header: ["alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"],
            payload: ["format": 7, "cipherCombo": "SIV_GCM", "shorteningThreshold": 220],
            rawKey: masterkey.rawKey
        )
        let store = InMemoryStore(objects: [
            "vault.cryptomator": Data(token.utf8),
            "masterkey.cryptomator": masterJSON,
        ])
        let location = VaultLocation.local()
        do {
            _ = try await VaultSession.unlock(location: location, passphrase: "pass", store: store)
            XCTFail("expected unsupportedFormat")
        } catch VaultError.unsupportedFormat(let format) {
            XCTAssertEqual(format, 7)
        }
    }

    func testUnsupportedCipherCombo() async throws {
        let masterkey = try Masterkey.createNew()
        let masterJSON = try MasterkeyFile.lock(
            masterkey: masterkey,
            vaultVersion: 999,
            passphrase: "pass",
            scryptCostParam: 16
        )
        let token = try VaultJWT.sign(
            header: ["alg": "HS256", "kid": "masterkeyfile:masterkey.cryptomator"],
            payload: ["format": 8, "cipherCombo": "AES_GCM", "shorteningThreshold": 220],
            rawKey: masterkey.rawKey
        )
        let store = InMemoryStore(objects: [
            "vault.cryptomator": Data(token.utf8),
            "masterkey.cryptomator": masterJSON,
        ])
        let location = VaultLocation.local()
        do {
            _ = try await VaultSession.unlock(location: location, passphrase: "pass", store: store)
            XCTFail("expected unsupportedCipherCombo")
        } catch VaultError.unsupportedCipherCombo(let combo) {
            XCTAssertEqual(combo, "AES_GCM")
        }
    }

    func testPathNotFoundAndNotAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-edge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try VaultFixture.create(at: root, passphrase: "edge-pass")
        let store = DirectoryObjectStore(root: root)
        let session = try await VaultSession.unlock(
            location: VaultLocation.local(),
            passphrase: "edge-pass",
            store: store
        )

        do {
            _ = try await session.resolve(cleartextPath: "/does-not-exist")
            XCTFail("expected pathNotFound")
        } catch VaultError.pathNotFound(let path) {
            XCTAssertEqual(path, "/does-not-exist")
        }
        do {
            _ = try await session.resolveFile(cleartextPath: "/notes")
            XCTFail("expected notAFile")
        } catch VaultError.notAFile(let path) {
            XCTAssertEqual(path, "/notes")
        }
    }
}

final class VaultLocationTests: XCTestCase {
    func testNormalizePrefixAddsTrailingSlash() {
        XCTAssertEqual(VaultLocation.normalizePrefix(""), "")
        XCTAssertEqual(VaultLocation.normalizePrefix("family"), "family/")
        XCTAssertEqual(VaultLocation.normalizePrefix("family/"), "family/")
    }

    func testKeyJoinsPrefix() {
        let location = VaultLocation(
            endpoint: URL(string: "http://127.0.0.1:9000")!,
            region: "us-east-1",
            bucket: "b",
            prefix: "family/",
            accessKey: "k"
        )
        XCTAssertEqual(location.key("vault.cryptomator"), "family/vault.cryptomator")
    }
}

final class DirLayoutTests: XCTestCase {
    func testShortenedNameIsDeterministic() {
        let first = DirLayout.shortenedName(ciphertextFileName: "abc.c9r")
        let second = DirLayout.shortenedName(ciphertextFileName: "abc.c9r")
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".c9s"))
    }
}
