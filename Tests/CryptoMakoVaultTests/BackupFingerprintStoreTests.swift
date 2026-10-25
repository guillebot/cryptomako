import Foundation
import XCTest
@testable import CryptoMakoShared

final class BackupFingerprintStoreTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var writes: [Int] = []
        var failNext = false
        var gate: DispatchSemaphore?
        func write(_ s: BackupSyncState) throws {
            gate?.wait()
            lock.lock(); defer { lock.unlock() }
            if failNext { failNext = false; throw CocoaError(.fileWriteUnknown) }
            writes.append(s.files.count)
        }
        var snapshot: [Int] { lock.lock(); defer { lock.unlock() }; return writes }
    }

    private func fp(_ n: Int) -> BackupFileFingerprint {
        BackupFileFingerprint(size: Int64(n), contentModification: Date(timeIntervalSinceReferenceDate: 0))
    }

    func testNonForcedSaveRespectsThresholdsAndRunsOffCaller() throws {
        let rec = Recorder()
        let store = BackupFingerprintStore(.empty, putThreshold: 3, timeThreshold: 3600) { try rec.write($0) }
        // lastSaveAt starts distantPast, so the very first commit persists (time gate).
        store.set("a", fp(1))
        XCTAssertTrue(store.notePutCommittedForPersist())
        try store.save()
        store.waitForPendingSaves()
        XCTAssertEqual(rec.snapshot, [1])
        XCTAssertFalse(store.isDirty)

        store.set("b", fp(2)); XCTAssertFalse(store.notePutCommittedForPersist())
        try store.save() // below threshold: no-op
        store.waitForPendingSaves()
        XCTAssertEqual(rec.snapshot, [1])
        store.set("c", fp(3)); _ = store.notePutCommittedForPersist()
        store.set("d", fp(4)); XCTAssertTrue(store.notePutCommittedForPersist())
        try store.save()
        store.waitForPendingSaves()
        XCTAssertEqual(rec.snapshot, [1, 4])
    }

    func testSetAndGetDoNotBlockOnInFlightWrite() throws {
        let rec = Recorder()
        rec.gate = DispatchSemaphore(value: 0)
        let store = BackupFingerprintStore(.empty, putThreshold: 1, timeThreshold: 3600) { try rec.write($0) }
        store.set("a", fp(1)); _ = store.notePutCommittedForPersist()
        try store.save() // returns immediately; writer is parked on the gate
        store.set("b", fp(2))
        XCTAssertEqual(store.get("b"), fp(2))
        // Overlapping non-forced save coalesces (skipped, stays dirty).
        _ = store.notePutCommittedForPersist()
        try store.save()
        XCTAssertTrue(store.isDirty)
        rec.gate?.signal()
        store.waitForPendingSaves()
        XCTAssertEqual(rec.snapshot, [1])
        rec.gate = nil
        // Forced save persists the newer state.
        try store.save(force: true)
        XCTAssertEqual(rec.snapshot, [1, 2])
        XCTAssertFalse(store.isDirty)
    }

    func testForcedSaveWaitsForInFlightThenWritesLatest() throws {
        let rec = Recorder()
        rec.gate = DispatchSemaphore(value: 0)
        let store = BackupFingerprintStore(.empty, putThreshold: 1, timeThreshold: 3600) { try rec.write($0) }
        store.set("a", fp(1)); _ = store.notePutCommittedForPersist()
        try store.save()
        store.set("b", fp(2))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            rec.gate?.signal(); rec.gate?.signal()
        }
        try store.save(force: true)
        XCTAssertEqual(rec.snapshot, [1, 2])
    }

    func testForcedSaveWithNothingDirtyStillDrainsInFlight() throws {
        let rec = Recorder()
        rec.gate = DispatchSemaphore(value: 0)
        let store = BackupFingerprintStore(.empty, putThreshold: 1, timeThreshold: 3600) { try rec.write($0) }
        store.set("a", fp(1)); _ = store.notePutCommittedForPersist()
        try store.save()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { rec.gate?.signal() }
        try store.save(force: true) // not dirty, but must not return before the write lands
        XCTAssertEqual(rec.snapshot, [1])
    }

    func testBackgroundFailureRemarksDirtyAndForcedSaveRetries() throws {
        let rec = Recorder()
        rec.failNext = true
        let store = BackupFingerprintStore(.empty, putThreshold: 1, timeThreshold: 3600) { try rec.write($0) }
        store.set("a", fp(1)); _ = store.notePutCommittedForPersist()
        try store.save()
        store.waitForPendingSaves()
        XCTAssertTrue(store.isDirty)
        XCTAssertNotNil(store.lastBackgroundSaveError)
        try store.save(force: true)
        XCTAssertEqual(rec.snapshot, [1])
        XCTAssertNil(store.lastBackgroundSaveError)
    }

    func testForcedSaveFailureThrowsAndStaysDirty() {
        let rec = Recorder()
        rec.failNext = true
        let store = BackupFingerprintStore(.empty) { try rec.write($0) }
        store.set("a", fp(1))
        XCTAssertThrowsError(try store.save(force: true))
        XCTAssertTrue(store.isDirty)
    }

    func testForcedSaveNoOpWhenClean() throws {
        let rec = Recorder()
        let store = BackupFingerprintStore(.empty) { try rec.write($0) }
        try store.save(force: true)
        XCTAssertEqual(rec.snapshot, [])
    }
}
