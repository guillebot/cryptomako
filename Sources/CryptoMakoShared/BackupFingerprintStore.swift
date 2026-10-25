import Foundation

/// Thread-safe in-memory Backup fingerprint index with off-lock, coalesced persistence.
///
/// Put workers call `set` / `get` constantly. Encoding the full map (hundreds of
/// thousands of keys, tens of MB of JSON) used to run while holding the same lock,
/// stalling every worker for the duration of the encode + atomic write. Now:
///
/// - `save()` snapshots the map under the lock (copy-on-write, cheap), clears the
///   dirty flag, and hands the encode + write to a serial background queue.
/// - While a background save is in flight, further non-forced saves are skipped and
///   the store stays dirty, so the next threshold hit (or the forced end-of-run
///   save) persists the newer state — overlapping saves coalesce instead of queueing.
/// - `save(force: true)` drains any in-flight write, then writes synchronously and
///   throws on failure, so Sync end / cancel / exit is durable before returning.
///
/// Persist thresholds and the on-disk format (`BackupSyncState` JSON) are unchanged.
public final class BackupFingerprintStore: @unchecked Sendable {
    public typealias Writer = @Sendable (BackupSyncState) throws -> Void

    private let lock = NSLock()
    private var files: [String: BackupFileFingerprint]
    /// Puts since the last persist snapshot.
    private var putsSinceSave = 0
    /// True when `files` changed since the last persist snapshot (or a write failed).
    private var dirty = false
    private var lastSaveAt = Date.distantPast
    private var saveInFlight = false
    private var lastBackgroundError: Error?

    private let putThreshold: Int
    private let timeThreshold: TimeInterval
    private let writer: Writer
    private let writeQueue = DispatchQueue(
        label: "net.gschimmel.cryptomako.backup-state.save",
        qos: .utility
    )

    public init(
        _ state: BackupSyncState,
        putThreshold: Int = BackupStatePersistPolicy.putThreshold,
        timeThreshold: TimeInterval = BackupStatePersistPolicy.timeThreshold,
        writer: @escaping Writer = { try $0.save() }
    ) {
        self.files = state.files
        self.putThreshold = putThreshold
        self.timeThreshold = timeThreshold
        self.writer = writer
    }

    public func snapshot() -> BackupSyncState {
        lock.lock(); defer { lock.unlock() }
        return BackupSyncState(files: files)
    }

    public func set(_ key: String, _ fp: BackupFileFingerprint) {
        lock.lock(); files[key] = fp; dirty = true; lock.unlock()
    }

    public func get(_ key: String) -> BackupFileFingerprint? {
        lock.lock(); defer { lock.unlock() }
        return files[key]
    }

    public var isDirty: Bool {
        lock.lock(); defer { lock.unlock() }
        return dirty
    }

    /// Last background (non-forced) write failure, cleared by a successful forced save.
    public var lastBackgroundSaveError: Error? {
        lock.lock(); defer { lock.unlock() }
        return lastBackgroundError
    }

    /// Count a committed put. Returns true when a (non-forced) `save()` should run.
    public func notePutCommittedForPersist() -> Bool {
        lock.lock(); defer { lock.unlock() }
        putsSinceSave += 1
        dirty = true
        return BackupStatePersistPolicy.shouldPersist(
            putsSinceSave: putsSinceSave,
            elapsed: Date().timeIntervalSince(lastSaveAt),
            putThreshold: putThreshold,
            timeThreshold: timeThreshold
        )
    }

    /// Persist when dirty.
    ///
    /// - Non-forced: respects the put/time thresholds, never blocks on disk I/O, and
    ///   is skipped (state stays dirty) while another background save is in flight.
    ///   Background failures re-mark the store dirty and are logged by the writer;
    ///   the forced end-of-run save retries and surfaces any persistent failure.
    /// - Forced: waits for in-flight writes, then writes synchronously and throws.
    public func save(force: Bool = false) throws {
        if force {
            // Serial queue: returns only after any in-flight background write.
            writeQueue.sync {}
        }

        lock.lock()
        let should = dirty && (
            force || BackupStatePersistPolicy.shouldPersist(
                putsSinceSave: putsSinceSave,
                elapsed: Date().timeIntervalSince(lastSaveAt),
                putThreshold: putThreshold,
                timeThreshold: timeThreshold
            )
        )
        if !should || (!force && saveInFlight) {
            lock.unlock()
            return
        }
        let snap = BackupSyncState(files: files)
        dirty = false
        putsSinceSave = 0
        lastSaveAt = Date()
        if !force { saveInFlight = true }
        lock.unlock()

        if force {
            var thrown: Error?
            writeQueue.sync {
                do { try writer(snap) } catch { thrown = error }
            }
            lock.lock()
            if let thrown {
                dirty = true
                lock.unlock()
                throw thrown
            }
            lastBackgroundError = nil
            lock.unlock()
            return
        }

        writeQueue.async { [self] in
            var failed: Error?
            do { try writer(snap) } catch { failed = error }
            lock.lock()
            saveInFlight = false
            if let failed {
                dirty = true
                lastBackgroundError = failed
            }
            lock.unlock()
        }
    }

    /// Block until queued background writes finish (tests / shutdown helpers).
    public func waitForPendingSaves() {
        writeQueue.sync {}
    }
}
