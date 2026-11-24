import CryptoMakoShared
import FileProvider
import XCTest

final class FileProviderCapabilityTests: XCTestCase {
    func testFilesAndFoldersAllowEvicting() {
        XCTAssertTrue(FileProviderCapabilitySets.file.contains(.allowsEvicting))
        XCTAssertTrue(FileProviderCapabilitySets.directory.contains(.allowsEvicting))
        XCTAssertTrue(FileProviderCapabilitySets.root.contains(.allowsEvicting))
    }

    func testEvictingBitIsSixtyFour() {
        // fileproviderctl reported 536870959 / 603979823 with this bit clear.
        XCTAssertEqual(NSFileProviderItemCapabilities.allowsEvicting.rawValue, 64)
        XCTAssertNotEqual(FileProviderCapabilitySets.file.rawValue & 64, 0)
        XCTAssertNotEqual(FileProviderCapabilitySets.directory.rawValue & 64, 0)
    }

    func testExistingDeleteModelUnchanged() {
        for caps in [FileProviderCapabilitySets.file, FileProviderCapabilitySets.directory] {
            XCTAssertTrue(caps.contains(.allowsReading))
            XCTAssertTrue(caps.contains(.allowsWriting))
            XCTAssertTrue(caps.contains(.allowsDeleting))
            XCTAssertTrue(caps.contains(.allowsRenaming))
            XCTAssertTrue(caps.contains(.allowsReparenting))
            // Move-to-Trash hit Finder -36; Delete is a remote delete via deleteItem.
            XCTAssertFalse(caps.contains(.allowsTrashing))
            XCTAssertFalse(caps.contains(.allowsExcludingFromSync))
        }
        XCTAssertTrue(FileProviderCapabilitySets.directory.contains(.allowsAddingSubItems))
        XCTAssertTrue(FileProviderCapabilitySets.directory.contains(.allowsContentEnumerating))
    }

    func testRootIsNotDeletable() {
        XCTAssertFalse(FileProviderCapabilitySets.root.contains(.allowsDeleting))
        XCTAssertFalse(FileProviderCapabilitySets.root.contains(.allowsRenaming))
        XCTAssertFalse(FileProviderCapabilitySets.root.contains(.allowsReparenting))
    }

    func testSystemContainersUnchanged() {
        XCTAssertEqual(
            FileProviderCapabilitySets.trashContainer,
            [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        )
        XCTAssertEqual(FileProviderCapabilitySets.workingSet, [.allowsReading, .allowsContentEnumerating])
    }

    func testFileMetadataVersionCarriesRevisionAndETag() {
        let v = String(decoding: FileProviderCapabilitySets.fileMetadataVersion(eTag: "abc"), as: UTF8.self)
        XCTAssertEqual(v, "caps-evict-v5|abc")
        // Old builds used the bare ETag; the new value must differ so FPFS refreshes caps.
        XCTAssertNotEqual(FileProviderCapabilitySets.fileMetadataVersion(eTag: "abc"), Data("abc".utf8))
        XCTAssertNotEqual(FileProviderCapabilitySets.metadataRevision, "caps-delete-v2")
    }
}

final class FileProviderEvictionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func safeFile(size: Int64 = 25_000_000, daysAgo: Double? = 90) -> EvictionCandidate {
        EvictionCandidate(
            isMaterialized: true,
            isUploaded: true,
            isUploading: false,
            hasUnresolvedConflicts: false,
            fileSize: size,
            lastAccess: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            verifiedOnRemote: true
        )
    }

    func testManualEvictsSafeDownloadedFile() {
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(), policy: nil, now: now), .evict)
    }

    func testSafetyChecks() {
        var c = safeFile()
        c.isDirectory = true
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.directory))

        c = safeFile(); c.isMaterialized = false
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.notDownloaded))

        c = safeFile(); c.isUploading = true
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.uploading))

        c = safeFile(); c.isUploaded = false
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.notUploaded))

        c = safeFile(); c.hasUnresolvedConflicts = true
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.conflict))

        c = safeFile(); c.verifiedOnRemote = false
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.notOnRemote))
    }

    func testSafetyBeatsPolicyThresholds() {
        var c = safeFile(size: 1, daysAgo: 1)
        c.isUploading = true
        let policy = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 30, minFileSizeMB: 10)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: policy, now: now), .skip(.uploading))
    }

    func testUnknownUploadStateDefersToRemoteCheck() {
        var c = safeFile()
        c.isUploaded = nil
        c.isUploading = nil
        c.verifiedOnRemote = nil
        // Pre-check passes; the reclaimer still requires verifiedOnRemote == true before evicting.
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .evict)
        c.verifiedOnRemote = false
        XCTAssertEqual(FileProviderEvictionPolicy.decide(c, policy: nil, now: now), .skip(.notOnRemote))
    }

    func testAutoPolicyAge() {
        let policy = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 30, minFileSizeMB: 0)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(daysAgo: 31), policy: policy, now: now), .evict)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(daysAgo: 29), policy: policy, now: now), .skip(.recentlyOpened))
        // Unknown access date is treated as recent (keep).
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(daysAgo: nil), policy: policy, now: now), .skip(.recentlyOpened))
        // 0 days = any age.
        let anyAge = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 0, minFileSizeMB: 0)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(daysAgo: nil), policy: anyAge, now: now), .evict)
    }

    func testAutoPolicySize() {
        let policy = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 0, minFileSizeMB: 10)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(size: 10_000_000), policy: policy, now: now), .evict)
        XCTAssertEqual(FileProviderEvictionPolicy.decide(safeFile(size: 9_999_999), policy: policy, now: now), .skip(.belowSizeThreshold))
    }

    func testPolicyDefaultsOffAndClamps() {
        XCTAssertFalse(AutoEvictionPolicy.default.enabled)
        let c = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: -5, minFileSizeMB: -1).clamped
        XCTAssertEqual(c.minDaysSinceAccess, 0)
        XCTAssertEqual(c.minFileSizeMB, 0)
        XCTAssertEqual(AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 30, minFileSizeMB: 20).summary, "not opened in 30 days, ≥ 20 MB")
    }

    func testRemoteCovers() {
        XCTAssertTrue(FileProviderEvictionPolicy.remoteCovers(localCleartextBytes: 100, remoteCiphertextBytes: 196))
        XCTAssertTrue(FileProviderEvictionPolicy.remoteCovers(localCleartextBytes: 0, remoteCiphertextBytes: 68))
        XCTAssertFalse(FileProviderEvictionPolicy.remoteCovers(localCleartextBytes: 25_000_000, remoteCiphertextBytes: 1_000))
        XCTAssertFalse(FileProviderEvictionPolicy.remoteCovers(localCleartextBytes: 1, remoteCiphertextBytes: nil))
    }

    func testPreferencesDecodeOldFileWithEvictionOff() throws {
        let old = Data(#"{"proxyMode":"system","textSize":"standard"}"#.utf8)
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertEqual(prefs.autoEviction, .default)
        XCTAssertFalse(prefs.autoEviction.enabled)
        var p = AppPreferences()
        p.autoEviction = AutoEvictionPolicy(enabled: true, minDaysSinceAccess: 7, minFileSizeMB: 50)
        let round = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round.autoEviction, p.autoEviction)
    }

    func testSummaryLine() {
        var s = EvictionSummary()
        s.evictedFiles = 2
        s.bytesFreed = 50
        s.recordSkip(.uploading)
        s.recordSkip(.notDownloaded)
        s.failed = 1
        s.firstError = "boom"
        XCTAssertEqual(
            s.line(formatBytes: { "\($0) B" }),
            "Freed 50 B — 2 files now online-only; kept uploading 1; 1 failed (boom)"
        )
    }
}
