import Foundation
import XCTest
@testable import CryptoMakoShared

final class BackupDirectoryResolutionCacheTests: XCTestCase {
    private actor FakeDirectoryStore {
        var lookupCount = 0
        var createCount = 0
        var failNextCreate = false

        func lookup(parentID: String, name: String) async -> String? {
            lookupCount += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
            return nil
        }

        func create(parentID: String, name: String) async throws -> String {
            createCount += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            if failNextCreate {
                failNextCreate = false
                throw CocoaError(.fileWriteUnknown)
            }
            return "shared-directory-id"
        }

        func counts() -> (lookups: Int, creates: Int) {
            (lookupCount, createCount)
        }

        func failOnce() {
            failNextCreate = true
        }
    }

    func testConcurrentResolvesCoalesceDirectoryCreation() async throws {
        let store = FakeDirectoryStore()
        let cache = BackupDirectoryResolutionCache(
            rootDirectoryID: "root",
            lookup: { await store.lookup(parentID: $0, name: $1) },
            create: { try await store.create(parentID: $0, name: $1) }
        )

        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask { try await cache.resolve("new-folder") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(values), ["shared-directory-id"])
        let counts = await store.counts()
        XCTAssertEqual(counts.lookups, 1)
        XCTAssertEqual(counts.creates, 1, "dir.c9r creation must happen exactly once")
    }

    func testFailedSharedTaskIsRemovedSoLaterResolveRetries() async throws {
        let store = FakeDirectoryStore()
        await store.failOnce()
        let cache = BackupDirectoryResolutionCache(
            rootDirectoryID: "root",
            lookup: { await store.lookup(parentID: $0, name: $1) },
            create: { try await store.create(parentID: $0, name: $1) }
        )

        do {
            _ = try await cache.resolve("retry-folder")
            XCTFail("first creation should fail")
        } catch {}
        let retried = try await cache.resolve("retry-folder")
        XCTAssertEqual(retried, "shared-directory-id")
        let counts = await store.counts()
        XCTAssertEqual(counts.creates, 2)
    }

    func testCancellingOneWaiterDoesNotPoisonSharedCreation() async throws {
        let store = FakeDirectoryStore()
        let cache = BackupDirectoryResolutionCache(
            rootDirectoryID: "root",
            lookup: { await store.lookup(parentID: $0, name: $1) },
            create: { try await store.create(parentID: $0, name: $1) }
        )

        let cancelled = Task { try await cache.resolve("shared-folder") }
        try await Task.sleep(nanoseconds: 2_000_000)
        let survivor = Task { try await cache.resolve("shared-folder") }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("cancelled waiter should observe cancellation")
        } catch is CancellationError {}
        let survivingValue = try await survivor.value
        XCTAssertEqual(survivingValue, "shared-directory-id")
        let counts = await store.counts()
        XCTAssertEqual(counts.creates, 1)
    }
}

final class BackupStateIntegrityTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-state-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testCountOrTimeThresholdTriggersPersist() {
        XCTAssertTrue(BackupStatePersistPolicy.shouldPersist(putsSinceSave: 512, elapsed: 0))
        XCTAssertTrue(BackupStatePersistPolicy.shouldPersist(putsSinceSave: 1, elapsed: 30))
        XCTAssertFalse(BackupStatePersistPolicy.shouldPersist(putsSinceSave: 511, elapsed: 29.9))
        XCTAssertTrue(BackupStatePersistPolicy.shouldPersist(putsSinceSave: 512, elapsed: 29.9))
        XCTAssertFalse(BackupStatePersistPolicy.shouldPersist(putsSinceSave: 0, elapsed: 0))
    }

    func testSaveFailureIsThrown() throws {
        let parentFile = scratch.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: parentFile)
        let destination = parentFile.appendingPathComponent("backup-sync-state.json")
        XCTAssertThrowsError(try BackupSyncState.empty.save(to: destination))
    }

    func testDualFailureSurfacesSaveWhenUploadAlsoFailed() {
        struct UploadFailed: Error, LocalizedError {
            var errorDescription: String? { "upload failed" }
        }
        struct SaveFailed: Error, LocalizedError {
            var errorDescription: String? { "index save failed" }
        }
        let onlyPrimary = BackupPostFailureSavePolicy.errorToThrow(
            primary: UploadFailed(),
            saveFailure: nil
        )
        XCTAssertEqual(onlyPrimary.localizedDescription, "upload failed")

        let both = BackupPostFailureSavePolicy.errorToThrow(
            primary: UploadFailed(),
            saveFailure: SaveFailed()
        )
        guard let dual = both as? BackupPostFailureSavePolicy.DualFailure else {
            return XCTFail("expected DualFailure when both upload and save fail")
        }
        XCTAssertEqual(dual.primaryDescription, "upload failed")
        XCTAssertEqual(dual.saveDescription, "index save failed")
        XCTAssertTrue(
            dual.localizedDescription.contains("index save failed"),
            "save failure must remain observable in the thrown error, not discarded"
        )
        XCTAssertTrue(dual.localizedDescription.contains("upload failed"))
    }

    func testCorruptIndexIsThrownAndNeverPresentedAsEmpty() throws {
        let file = scratch.appendingPathComponent("backup-sync-state.json")
        try Data("{not-json".utf8).write(to: file)
        XCTAssertThrowsError(try BackupSyncState.load(from: file))
    }

    func testMissingIndexIsLegitimatelyEmpty() throws {
        let file = scratch.appendingPathComponent("missing.json")
        XCTAssertEqual(try BackupSyncState.load(from: file), .empty)
    }
}

final class SMBMountIdentityTests: XCTestCase {
    func testRealSMBMountIdentityMatches() {
        XCTAssertTrue(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share-2",
            isLocal: false,
            mountedFrom: "//host/share",
            expectedSMBURL: "smb://host/share"
        ))
    }

    func testLocalVolumeWithSameNameIsRejected() {
        XCTAssertFalse(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share",
            isLocal: true,
            mountedFrom: "/dev/disk9s1",
            expectedSMBURL: "smb://host/share"
        ))
    }

    func testWrongHostOrShareIsRejected() {
        XCTAssertFalse(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share",
            isLocal: false,
            mountedFrom: "//other/share",
            expectedSMBURL: "smb://host/share"
        ))
        XCTAssertFalse(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share",
            isLocal: false,
            mountedFrom: "//host/other",
            expectedSMBURL: "smb://host/share"
        ))
    }

    func testDigitSuffixDuplicateMountStillRequiresHostAndShare() {
        XCTAssertTrue(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share-2",
            isLocal: false,
            mountedFrom: "//user@host/share",
            expectedSMBURL: "smb://host/share"
        ))
        XCTAssertFalse(SMBVolumeNameMatch.mountMatches(
            volumeLeaf: "share-2",
            isLocal: false,
            mountedFrom: "//host/share-2",
            expectedSMBURL: "smb://host/share"
        ))
    }
}

final class BackupPruneCharacterizationTests: XCTestCase {
    func testCurrentFileAndDirectoryDecisionsArePreserved() {
        let index = BackupPruneIndex(localFiles: [
            "kept.txt",
            "folder/nested.txt",
            ".hidden",
            "excluded.tmp",
        ])
        XCTAssertTrue(index.containsFile("kept.txt"))
        XCTAssertFalse(index.containsFile("missing.txt"))
        XCTAssertTrue(index.hasLocalUnder("folder"))
        XCTAssertFalse(index.hasLocalUnder("vault-only"))
        XCTAssertTrue(index.hasLocalUnder(""))
    }

    func testFailedScanPrunesNothing() {
        XCTAssertFalse(BackupPruneIndex.shouldPrune(scanCompleted: false))
        XCTAssertTrue(BackupPruneIndex.shouldPrune(scanCompleted: true))
    }

    func testStateKeyRemovalIsBatchedButScopeIsUnchanged() {
        let keys = [
            "Photos/gone.txt",
            "Photos/gone-dir/child.txt",
            "Photos/kept.txt",
            "Other/gone.txt",
        ]
        XCTAssertEqual(
            BackupPruneStateRemoval.keysToRemove(
                from: keys,
                vaultFolderName: "Photos",
                deletedFiles: ["gone.txt"],
                deletedDirectories: ["gone-dir"]
            ),
            ["Photos/gone.txt", "Photos/gone-dir/child.txt"]
        )
    }

    func testNestedDeletedDirectoryRemovesDeepDescendantsOnlyUnderThatFolder() {
        let keys = [
            "Photos/a/b/c/deep.txt",
            "Photos/a/sibling.txt",
            "Photos/other.txt",
        ]
        XCTAssertEqual(
            BackupPruneStateRemoval.keysToRemove(
                from: keys,
                vaultFolderName: "Photos",
                deletedFiles: [],
                deletedDirectories: ["a/b"]
            ),
            ["Photos/a/b/c/deep.txt"]
        )
    }

    func testHasLocalUnderRequiresPathComponentBoundary() {
        let index = BackupPruneIndex(localFiles: ["folder-extra/file.txt", "folder/nested.txt"])
        XCTAssertTrue(index.hasLocalUnder("folder"))
        XCTAssertTrue(index.hasLocalUnder("folder-extra"))
        XCTAssertFalse(index.hasLocalUnder("fold"))
        XCTAssertFalse(index.containsFile("folder"))
    }
}

final class EncryptionTempCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let sixHours: TimeInterval = 6 * 60 * 60

    func testMatchesOnlyAppEncryptionTempPattern() {
        let uuid = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        XCTAssertTrue(EncryptionTempCleanup.matchesAppPattern("cryptomako-enc-\(uuid).c9r"))
        // Decrypt temps / unrelated names must never be selected.
        XCTAssertFalse(EncryptionTempCleanup.matchesAppPattern("cryptomako-\(uuid).c9r"))
        XCTAssertFalse(EncryptionTempCleanup.matchesAppPattern("cryptomako-enc-\(uuid).tmp"))
        XCTAssertFalse(EncryptionTempCleanup.matchesAppPattern("cryptomako-enc-not-a-uuid.c9r"))
        XCTAssertFalse(EncryptionTempCleanup.matchesAppPattern("other-enc-\(uuid).c9r"))
        XCTAssertFalse(EncryptionTempCleanup.matchesAppPattern(".DS_Store"))
    }

    func testDeletesOnlyStaleMatchingTemps() {
        let uuidOld = "11111111-1111-1111-1111-111111111111"
        let uuidFresh = "22222222-2222-2222-2222-222222222222"
        let uuidOther = "33333333-3333-3333-3333-333333333333"
        let entries: [(name: String, modificationDate: Date)] = [
            ("cryptomako-enc-\(uuidOld).c9r", now.addingTimeInterval(-(sixHours + 1))),
            ("cryptomako-enc-\(uuidFresh).c9r", now.addingTimeInterval(-(sixHours - 60))),
            ("cryptomako-\(uuidOther).c9r", now.addingTimeInterval(-(sixHours + 1))),
            ("unrelated.txt", now.addingTimeInterval(-(sixHours + 1))),
        ]
        XCTAssertEqual(
            EncryptionTempCleanup.namesToDelete(entries: entries, now: now, minAge: sixHours),
            ["cryptomako-enc-\(uuidOld).c9r"]
        )
    }

    func testAgeThresholdBoundaryIsInclusiveOfCutoff() {
        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let atCutoff = now.addingTimeInterval(-sixHours)
        let justAfterCutoff = now.addingTimeInterval(-(sixHours - 1))
        XCTAssertEqual(
            EncryptionTempCleanup.namesToDelete(
                entries: [("cryptomako-enc-\(uuid).c9r", atCutoff)],
                now: now,
                minAge: sixHours
            ),
            ["cryptomako-enc-\(uuid).c9r"]
        )
        XCTAssertEqual(
            EncryptionTempCleanup.namesToDelete(
                entries: [("cryptomako-enc-\(uuid).c9r", justAfterCutoff)],
                now: now,
                minAge: sixHours
            ),
            []
        )
    }
}
