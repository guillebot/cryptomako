import XCTest
import Security

@testable import CryptoMakoShared
@testable import CryptoMakoVault

final class ItemIdentifierTests: XCTestCase {
    func testRootAndDirectory() {
        XCTAssertEqual(ItemIdentifier(rawValue: "d:"), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: ""), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: "root"), .root)
        XCTAssertEqual(ItemIdentifier(rawValue: "d:abc")?.rawValue, "d:abc")
        if case .directory(let id, let parent) = ItemIdentifier(rawValue: "d:abc") {
            XCTAssertEqual(id, "abc")
            XCTAssertNil(parent)
        } else {
            XCTFail("expected directory")
        }
        if case .directory(let id, let parent) = ItemIdentifier(rawValue: "d:parent/child") {
            XCTAssertEqual(id, "child")
            XCTAssertEqual(parent, "parent")
            XCTAssertEqual(ItemIdentifier.directory(dirId: id, parentDirId: parent).rawValue, "d:parent/child")
        } else {
            XCTFail("expected directory with parent")
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
        XCTAssertFalse(settings.isComplete)
        XCTAssertEqual(settings.s3EndpointProblem, "Endpoint must use https://.")
    }

    func testHTTPSEndpointIsComplete() {
        let settings = VaultSettings(
            storageMode: .s3,
            endpoint: "https://minio.example:9000",
            bucket: "b",
            accessKey: "k"
        )
        XCTAssertNil(settings.s3EndpointProblem)
        XCTAssertTrue(settings.isComplete)
    }

    func testEndpointRejectsUserinfo() {
        let settings = VaultSettings(
            storageMode: .s3,
            endpoint: "https://key:secret@minio.example:9000",
            bucket: "b",
            accessKey: "k"
        )
        XCTAssertEqual(settings.s3EndpointProblem, "Endpoint must not include a username or password.")
        XCTAssertFalse(settings.isComplete)
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
        do {
            try CredentialStore.save("secret-value", account: account, useAccessGroup: false)
        } catch CredentialStore.StoreError.unhandled(let status) where status == errSecMissingEntitlement {
            // GitHub Actions / unsigned hosts lack Keychain entitlements (-34018).
            // Do not weaken production Keychain; skip the round-trip when unavailable.
            throw XCTSkip("Keychain unavailable in this environment (errSecMissingEntitlement / -34018)")
        }
        XCTAssertEqual(try CredentialStore.read(account: account, useAccessGroup: false), "secret-value")
        CredentialStore.delete(account: account, useAccessGroup: false)
        XCTAssertThrowsError(try CredentialStore.read(account: account, useAccessGroup: false))
    }
}

final class UploadBandwidthLimiterTests: XCTestCase {
    func testAcquireLargerThanBurstCompletes() async {
        // 1 MB/s bucket holds only 1 MB; old code deadlocked forever on >burst.
        let rate = 1_000_000.0
        let limiter = UploadBandwidthLimiter(bytesPerSecond: rate)
        let start = CFAbsoluteTimeGetCurrent()
        await limiter.acquire(Int64(3.5 * rate))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        // Initial 1s burst is free; remaining 2.5 MB needs ~2.5s.
        XCTAssertGreaterThanOrEqual(elapsed, 2.0)
        XCTAssertLessThan(elapsed, 6.0)
    }

    func testZeroRateIsImmediateNoOp() async {
        let limiter = UploadBandwidthLimiter(bytesPerSecond: 0)
        let start = CFAbsoluteTimeGetCurrent()
        await limiter.acquire(100_000_000)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.5)
    }

    func testDisabledFromPreferencesWhenCapOff() {
        var prefs = AppPreferences()
        prefs.limitSyncUploadBandwidth = false
        prefs.syncUploadCapMbps = 100
        XCTAssertNil(UploadBandwidthLimiter.fromPreferences(prefs))
    }
}

final class TransferMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TransferMetrics.reset()
    }

    override func tearDown() {
        TransferMetrics.reset()
        super.tearDown()
    }

    func testLegacySnapshotDecodesWithoutFailureHistory() throws {
        let json = """
        {
          "inFlight": 0,
          "completedPuts": 3,
          "failedPuts": 2,
          "completedDeletes": 0,
          "bytesUploaded": 42,
          "bytesDownloaded": 0,
          "uploadBytesPerSecond": 0,
          "updatedAt": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(TransferSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.failedPuts, 2)
        XCTAssertTrue(snapshot.failureHistory.isEmpty)
        XCTAssertNil(snapshot.latestRunID)
    }

    func testFailureIsTrackedAndLaterSuccessResolvesIt() {
        let runID = TransferMetrics.beginRun()
        let failedToken = TransferMetrics.beginPut(
            name: "albums/photo.jpg",
            sourceID: "source-1",
            runID: runID
        )
        TransferMetrics.endPutFailure(
            token: failedToken,
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
            )
        )

        var snapshot = TransferMetrics.load()
        XCTAssertEqual(snapshot.currentRunUnresolvedFailures.count, 1)
        XCTAssertEqual(snapshot.currentRunUnresolvedFailures.first?.path, "albums/photo.jpg")
        XCTAssertEqual(snapshot.currentRunUnresolvedFailures.first?.category, "Network")
        XCTAssertEqual(snapshot.currentRunUnresolvedFailures.first?.attempts, 5)
        XCTAssertEqual(snapshot.currentRunUnresolvedFailures.first?.retryable, true)

        let retryToken = TransferMetrics.beginPut(
            name: "albums/photo.jpg",
            sourceID: "source-1",
            runID: UUID()
        )
        TransferMetrics.endPutSuccess(token: retryToken, bytes: 123)
        snapshot = TransferMetrics.load()
        XCTAssertTrue(snapshot.unresolvedFailures.isEmpty)
        XCTAssertEqual(snapshot.failureHistory.first?.status, .resolved)
        XCTAssertNotNil(snapshot.failureHistory.first?.resolvedAt)
    }

    func testClearFailureHistoryPreservesSuccessfulCounters() {
        let token = TransferMetrics.beginPut(name: "photo.jpg")
        TransferMetrics.endPutSuccess(token: token, bytes: 10)
        let failed = TransferMetrics.beginPut(name: "bad.jpg")
        TransferMetrics.endPutFailure(
            token: failed,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        )

        TransferMetrics.clearFailureHistory()
        let snapshot = TransferMetrics.load()
        XCTAssertEqual(snapshot.completedPuts, 1)
        XCTAssertEqual(snapshot.bytesUploaded, 10)
        XCTAssertEqual(snapshot.failedPuts, 0)
        XCTAssertTrue(snapshot.failureHistory.isEmpty)
    }

    func testFailureHistoryIsBounded() {
        for index in 0..<205 {
            let token = TransferMetrics.beginPut(name: "file-\(index)")
            TransferMetrics.endPutFailure(
                token: token,
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            )
        }
        let snapshot = TransferMetrics.load()
        XCTAssertEqual(snapshot.failedPuts, 205)
        XCTAssertEqual(snapshot.failureHistory.count, 200)
        XCTAssertEqual(snapshot.failureHistory.first?.path, "file-5")
        XCTAssertEqual(snapshot.failureHistory.last?.path, "file-204")
    }
}

final class AppPreferencesTextSizeTests: XCTestCase {
    func testMissingTextSizeDecodesAsStandard() throws {
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"proxyMode":"direct"}"#.utf8))
        XCTAssertEqual(prefs.textSize, .standard)
        XCTAssertEqual(prefs.proxyMode, .direct)
    }

    func testTextSizeRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.textSize = .extraLarge
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(decoded.textSize, .extraLarge)
    }
}
