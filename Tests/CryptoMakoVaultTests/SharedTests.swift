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
        let live = UploadBandwidthLimiter.live(from: prefs)
        XCTAssertEqual(live.bytesPerSecond, 0)
    }

    func testHotReloadDisablesMidAcquire() async {
        let limiter = UploadBandwidthLimiter(bytesPerSecond: 8_000) // 8 KB/s
        await limiter.acquire(8_000) // burn the 1s burst
        let task = Task {
            await limiter.acquire(80_000) // would take ~10s at 8 KB/s
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        limiter.setBytesPerSecond(0)
        let start = CFAbsoluteTimeGetCurrent()
        await task.value
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1.0)
        XCTAssertEqual(limiter.bytesPerSecond, 0)
    }

    func testHotReloadApplyPreferencesRaisesCap() {
        var prefs = AppPreferences()
        prefs.limitSyncUploadBandwidth = true
        prefs.syncUploadCapMbps = 10
        let limiter = UploadBandwidthLimiter.live(from: prefs)
        XCTAssertEqual(limiter.bytesPerSecond, 10 * 1_000_000 / 8, accuracy: 1)
        prefs.syncUploadCapMbps = 50
        limiter.applyPreferences(prefs)
        XCTAssertEqual(limiter.bytesPerSecond, 50 * 1_000_000 / 8, accuracy: 1)
        prefs.limitSyncUploadBandwidth = false
        limiter.applyPreferences(prefs)
        XCTAssertEqual(limiter.bytesPerSecond, 0)
    }

    func testHotReloadEnablesFromUnlimited() async {
        // free → 10 Mbps: enabling path must arm the bucket and pace the next acquire.
        let limiter = UploadBandwidthLimiter.live(from: AppPreferences())
        XCTAssertEqual(limiter.bytesPerSecond, 0)
        await limiter.acquire(50_000_000) // no-op while unlimited

        var prefs = AppPreferences()
        prefs.limitSyncUploadBandwidth = true
        prefs.syncUploadCapMbps = 10
        limiter.applyPreferences(prefs)
        let expected = 10.0 * 1_000_000 / 8
        XCTAssertEqual(limiter.bytesPerSecond, expected, accuracy: 1)

        // Charge ~2s of budget after the 1s burst → should take ~1s+, not return instantly.
        let start = CFAbsoluteTimeGetCurrent()
        await limiter.acquire(Int64(expected * 2))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.7)
        XCTAssertLessThan(elapsed, 4.0)
    }

    func testSetBytesPerSecondEnablingPath() {
        let limiter = UploadBandwidthLimiter(bytesPerSecond: 0)
        let rate = 10.0 * 1_000_000 / 8
        limiter.setBytesPerSecond(rate)
        XCTAssertEqual(limiter.bytesPerSecond, rate, accuracy: 1)
        limiter.setBytesPerSecond(0)
        XCTAssertEqual(limiter.bytesPerSecond, 0)
    }
}

final class TransferRateFormatTests: XCTestCase {
    func testFormatRateUsesDecimalBits() {
        XCTAssertEqual(TransferSnapshot.formatRate(0), "0 bps")
        // 125 bytes/s → 1000 bits/s → 1.0 kbps
        XCTAssertEqual(TransferSnapshot.formatRate(125), "1.0 kbps")
        // 1_000_000 bytes/s → 8 Mbps
        XCTAssertEqual(TransferSnapshot.formatRate(1_000_000), "8.0 Mbps")
        // 91.1e6 bytes/s → 728.8 Mbps (legacy MB/s display was ambiguous)
        XCTAssertEqual(TransferSnapshot.formatRate(91_100_000), "728.8 Mbps")
    }

    func testBusyAverageDoesNotInflateOnShortGaps() {
        // Old bug: 91 MB dumped into a 1s UI batch / 0.35s window → ~260 MB/s.
        // Honest: same bytes over a 6s busy period ≈ 15 MB/s ≈ 120 Mbps.
        let avg = TransferSnapshot.busyAverageBytesPerSecond(
            completedBytes: 91_100_000,
            elapsed: 6
        )
        XCTAssertEqual(avg!, 91_100_000 / 6, accuracy: 1)
        XCTAssertNil(TransferSnapshot.busyAverageBytesPerSecond(
            completedBytes: 91_100_000,
            elapsed: 0.2
        ))
    }
}

final class SlidingByteRateMeterTests: XCTestCase {
    func testSteadyRateOverWindow() {
        var meter = SlidingByteRateMeter(
            windowSeconds: 5,
            minElapsed: 1,
            maxBytesPerSecond: nil,
            minSampleGap: 0.1
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(meter.observe(cumulativeBytes: 0, at: t0))
        // 12.5 MB/s cleartext ≈ 100 Mbps for 5s.
        let rate = meter.observe(cumulativeBytes: 62_500_000, at: t0.addingTimeInterval(5))
        XCTAssertEqual(rate!, 12_500_000, accuracy: 1)
        XCTAssertEqual(rate! * 8 / 1_000_000, 100, accuracy: 0.1)
    }

    func testResetThenBurstInventGbps_documentsOldBug() {
        // The mid-Sync "reset busy window on cap change" bug: zero the meter, then
        // PutUIBatcher dumps ~325 MB of already-in-flight completions into ~1s → 2.6 Gbps.
        var meter = SlidingByteRateMeter(
            windowSeconds: 5,
            minElapsed: 0.5,
            maxBytesPerSecond: nil,
            minSampleGap: 0.1
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        meter.reset()
        _ = meter.observe(cumulativeBytes: 0, at: t0)
        let bogus = meter.observe(cumulativeBytes: 325_000_000, at: t0.addingTimeInterval(1.0))!
        XCTAssertGreaterThan(bogus * 8, 2_000_000_000, "reset+burst still invents >2 Gbps")
    }

    func testCapRemovalBurstWithoutResetStaysBelowGbps() {
        // Correct path: keep the sliding window across unlimited; a 325 MB completion
        // burst is diluted over the prior capped samples' wall span.
        var meter = SlidingByteRateMeter(
            windowSeconds: 8,
            minElapsed: 1,
            maxBytesPerSecond: nil,
            minSampleGap: 0.1
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_200)
        _ = meter.observe(cumulativeBytes: 0, at: t0)
        // ~100 Mbps cleartext for 8s.
        let capped = meter.observe(cumulativeBytes: 100_000_000, at: t0.addingTimeInterval(8))!
        XCTAssertEqual(capped * 8 / 1_000_000, 100, accuracy: 1)

        // Many parallel puts finish right after removing the limit (UI batch).
        let after = meter.observe(
            cumulativeBytes: 100_000_000 + 325_000_000,
            at: t0.addingTimeInterval(9)
        )!
        let mbps = after * 8 / 1_000_000
        XCTAssertLessThan(mbps, 1000, "continuing window must not show Gbps; got \(mbps) Mbps")
        // Diluted over ~9s → hundreds of Mbps is ok; multi-Gbps is not.
        XCTAssertGreaterThan(mbps, 50)
    }

    func testAbsurdityClampCapsNonsense() {
        var meter = SlidingByteRateMeter(
            windowSeconds: 5,
            minElapsed: 0.5,
            maxBytesPerSecond: SlidingByteRateMeter.absurdityClampBytesPerSecond,
            minSampleGap: 0.1
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_300)
        _ = meter.observe(cumulativeBytes: 0, at: t0)
        let rate = meter.observe(cumulativeBytes: 5_000_000_000, at: t0.addingTimeInterval(1))!
        XCTAssertEqual(rate, SlidingByteRateMeter.absurdityClampBytesPerSecond, accuracy: 1)
    }

    func testShortSpanReturnsNilSoCallerKeepsLastRate() {
        var meter = SlidingByteRateMeter(
            windowSeconds: 8,
            minElapsed: 1.0,
            maxBytesPerSecond: nil,
            minSampleGap: 0.05
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_400)
        _ = meter.observe(cumulativeBytes: 0, at: t0)
        XCTAssertNil(meter.observe(cumulativeBytes: 50_000_000, at: t0.addingTimeInterval(0.4)))
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
        XCTAssertEqual(decoded.textSize.pointAdjustment, 6)
    }

    func testTextSizePointAdjustments() {
        XCTAssertEqual(AppPreferences.TextSize.compact.pointAdjustment, 0)
        XCTAssertEqual(AppPreferences.TextSize.standard.pointAdjustment, 2)
        XCTAssertEqual(AppPreferences.TextSize.large.pointAdjustment, 4)
        XCTAssertEqual(AppPreferences.TextSize.extraLarge.pointAdjustment, 6)
    }
}

final class SyncPutWorkerCountsTests: XCTestCase {
    func testLocalSourceUsesSettingsUnchanged() {
        let w = SyncPutWorkerCounts.effective(small: 96, medium: 32, large: 4, isNetworkSource: false, capNetworkSources: true)
        XCTAssertEqual(w, SyncPutWorkerCounts(small: 96, medium: 32, large: 4, isCapped: false))
        XCTAssertEqual(w.total, 132)
    }

    func testNetworkSourceCapsAt16_6_2() {
        let w = SyncPutWorkerCounts.effective(small: 96, medium: 32, large: 4, isNetworkSource: true, capNetworkSources: true)
        XCTAssertEqual(w, SyncPutWorkerCounts(small: 16, medium: 6, large: 2, isCapped: true))
        XCTAssertEqual(w.summary, "16 / 6 / 2")
    }

    func testNetworkCapNeverRaisesLowerSettings() {
        let w = SyncPutWorkerCounts.effective(small: 8, medium: 4, large: 1, isNetworkSource: true, capNetworkSources: true)
        XCTAssertEqual(w, SyncPutWorkerCounts(small: 8, medium: 4, large: 1, isCapped: false))
        let partial = SyncPutWorkerCounts.effective(small: 8, medium: 4, large: 4, isNetworkSource: true, capNetworkSources: true)
        XCTAssertEqual(partial, SyncPutWorkerCounts(small: 8, medium: 4, large: 2, isCapped: true))
    }

    func testToggleOffDisablesNetworkCap() {
        let w = SyncPutWorkerCounts.effective(small: 96, medium: 32, large: 4, isNetworkSource: true, capNetworkSources: false)
        XCTAssertEqual(w, SyncPutWorkerCounts(small: 96, medium: 32, large: 4, isCapped: false))
    }

    func testPreferencesEffectiveWorkersClampsThenCaps() {
        var prefs = AppPreferences()
        prefs.syncSmallPutConcurrency = 999 // clamps to 256
        prefs.syncMediumPutConcurrency = 0 // clamps to 1
        prefs.syncLargePutConcurrency = 4
        XCTAssertEqual(prefs.effectivePutWorkers(isNetworkSource: false), SyncPutWorkerCounts(small: 256, medium: 1, large: 4))
        XCTAssertEqual(prefs.effectivePutWorkers(isNetworkSource: true), SyncPutWorkerCounts(small: 16, medium: 1, large: 2, isCapped: true))
        prefs.capSMBPutWorkers = false
        XCTAssertEqual(prefs.effectivePutWorkers(isNetworkSource: true), SyncPutWorkerCounts(small: 256, medium: 1, large: 4))
    }

    func testCapSMBPutWorkersDefaultsTrueForOldFiles() throws {
        let old = #"{"proxyMode":"system","syncLargePutConcurrency":4}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertTrue(prefs.capSMBPutWorkers)
        var off = prefs
        off.capSMBPutWorkers = false
        let round = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(round.capSMBPutWorkers)
    }

    func testNetworkFilesystemTypeNames() {
        for name in ["smbfs", "nfs", "afpfs", "webdav", "SMBFS"] {
            XCTAssertTrue(NetworkFilesystem.isNetworkTypeName(name), name)
        }
        for name in ["apfs", "hfs", "msdos", "exfat", "devfs", ""] {
            XCTAssertFalse(NetworkFilesystem.isNetworkTypeName(name), name)
        }
    }

    func testLocalTempDirIsNotNetwork() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertNotNil(NetworkFilesystem.typeName(atPath: tmp))
        XCTAssertFalse(NetworkFilesystem.isOnNetworkFilesystem(path: tmp))
        XCTAssertFalse(NetworkFilesystem.isOnNetworkFilesystem(path: "/definitely/not/here/\(UUID().uuidString)"))
    }
}
