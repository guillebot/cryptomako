import CryptoMakoShared
import CryptoMakoS3
import CryptoMakoVault
import Foundation
import OSLog

/// Walks picked local folders and writes into the vault via `VaultSession`
/// (encrypt + remote put per file). Directories stay ordered; file puts run with
/// bounded parallelism (many small files, few large) to fill the network pipe.
///
/// Two strict phases per source, never overlapping:
///
/// 1. **Scan** — enumerate the local (or SMB) tree with prefetched size/mtime,
///    apply excludes and `BackupWalkSkipPolicy`, and record what must upload in a
///    `BackupScanPlan` (relative path, size, mtime only). No S3/vault LIST, no
///    `dir.c9r`, no put, no waiting on the network. The scan finishes even when
///    nothing has uploaded yet, and when it finishes the UI shows how many files
///    and bytes still have to be transferred.
/// 2. **Upload** — only after the scan completed (and the source is still
///    reachable) do the small/medium/large worker pools consume the frozen plan.
///    Remaining = to-upload − uploaded keeps updating while puts run.
///
/// Earlier builds let the enumerator feed puts while it walked, either parking the
/// walk on a 512-slot semaphore (so unchanged files could not be skipped until SMB
/// reads and vault lookups returned) or overlapping scan and upload with unbounded
/// streams. Both were rejected: the scan must complete first, then uploads start.
///
/// Transfer mode (`AppPreferences.backupTransferMode`):
/// - **backup** (default): put/update only. Never deletes the local source. Never
///   deletes vault extras missing from source. Does not retain skipped paths.
/// - **sync**: same puts, then delete remote ciphertext under `Backups/<folder>/`
///   that is missing from the local tree (ObjectStore delete, fail-closed). Never
///   deletes the local source. Scope is that source’s vault folder only. The local
///   file set for orphan prune is collected during the scan.

@MainActor
final class BackupSyncEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(files: Int, bytes: Int64)
        case failed(String)
    }

    /// Coarse UI phase for Backup Sync.
    /// `.walking` is local enumeration only (size/mtime + fingerprint skip); no put
    /// runs during it. `.uploading` starts only after the scan completed.
    enum Phase: String, Equatable {
        case idle = ""
        case preparing = "Preparing sources…"
        case walking = "Scanning local tree…"
        case uploading = "Uploading to vault…"
        case pruning = "Removing vault-only files…"
        case finishing = "Finishing…"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentSourceName: String = ""
    /// True after the local enumerator finishes feeding the put streams for the
    /// current source (totals for that source stop growing; queue drains).
    @Published private(set) var walkFinished: Bool = false
    /// Bumped once per coalesced progress publish so SwiftUI/menu observers
    /// refresh without one `objectWillChange` per counter field.
    @Published private(set) var progressEpoch: UInt64 = 0

    /// High-churn Sync metrics — mutated in batches then published via `progressEpoch`.
    private(set) var currentPath: String = ""
    /// Skipped + uploaded (processed count for captions; not the upload % numerator).
    private(set) var filesDone: Int = 0
    private(set) var bytesDone: Int64 = 0
    /// Files discovered so far (freezes when walk finishes). Not the upload % denominator.
    private(set) var filesTotal: Int = 0
    private(set) var bytesTotal: Int64 = 0
    /// Eligible files seen during the single walk (same as `filesTotal` while running).
    private(set) var filesDiscovered: Int = 0
    private(set) var bytesDiscovered: Int64 = 0
    /// Files the scan decided must upload (not skipped). Grows during the scan and
    /// is final once `walkFinished` — that is the "still to transfer" figure the
    /// user sees before the first put starts. Accumulates across sources.
    private(set) var filesToUpload: Int = 0
    private(set) var bytesToUpload: Int64 = 0
    /// Files skipped because unchanged (local index) or already present in the vault.
    private(set) var filesSkipped: Int = 0
    private(set) var bytesSkipped: Int64 = 0
    /// Completed remote puts (cleartext bytes also in `bytesUploaded`).
    private(set) var filesUploaded: Int = 0
    private(set) var bytesUploaded: Int64 = 0
    /// Vault ciphertext files removed in Sync mode (orphan prune). Always 0 in Backup mode.
    private(set) var filesDeleted: Int = 0
    /// Job upload rate (cleartext bytes committed in the put phase only; skips excluded).
    private(set) var uploadBytesPerSecond: Double = 0

    /// Primary status line for the Backup UI.
    var phaseLabel: String { phase.rawValue }

    /// Files / bytes still to transfer: to-upload minus uploaded. Exact once the
    /// scan finished; while scanning it is "found so far".
    var filesRemaining: Int { max(0, filesToUpload - filesUploaded) }
    var bytesRemaining: Int64 { max(0, bytesToUpload - bytesUploaded) }

    /// Human line for the Backup UI and menu tooltip (provisional mid-scan;
    /// settled "left to upload" after the walk). Copy lives in BackupUploadProgress.
    var remainingLabel: String {
        BackupUploadProgress.remainingLabel(
            isRunning: isRunning,
            walkFinished: walkFinished,
            filesRemaining: filesRemaining,
            bytesRemaining: bytesRemaining,
            filesUploaded: filesUploaded
        )
    }

    /// Compact Discovered = Skipped + To upload · Uploaded counter line.
    var counterBreakdown: String {
        BackupUploadProgress.counterBreakdown(
            filesDiscovered: filesDiscovered,
            filesSkipped: filesSkipped,
            bytesSkipped: bytesSkipped,
            filesToUpload: filesToUpload,
            bytesToUpload: bytesToUpload,
            filesUploaded: filesUploaded,
            bytesUploaded: bytesUploaded
        )
    }

    nonisolated private static let syncLog = Logger(subsystem: "net.gschimmel.cryptomako", category: "backup-sync")

    private var task: Task<Void, Never>?
    /// Identifies the in-flight run so a cancelled previous task cannot mark the new one failed.
    private var runToken: UInt64 = 0
    /// True from the moment a run starts until the click that started it has finished.
    /// The Backup button is removed and a Cancel button appears in that same click;
    /// AppKit delivers that as cancel, which would stop the run immediately.
    private var suppressCancel = false
    private var putRateWindowStartedAt: Date?
    private var putRateWindowBytes: Int64 = 0

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True when the ProgressView should be determinate (post-scan upload %).
    var hasDeterminateUploadProgress: Bool {
        switch state {
        case .running:
            return walkFinished
        case .finished:
            return true
        default:
            return false
        }
    }

    /// After scan: uploadedBytes / bytesToUpload (skips excluded). During scan: 0
    /// (UI should use an indeterminate bar via `hasDeterminateUploadProgress`).
    var progressFraction: Double {
        switch state {
        case .finished:
            return 1
        case .running:
            return BackupUploadProgress.fraction(
                walkFinished: walkFinished,
                bytesUploaded: bytesUploaded,
                bytesToUpload: bytesToUpload
            ) ?? 0
        default:
            return 0
        }
    }

    var progressPercentLabel: String {
        switch state {
        case .running:
            return BackupUploadProgress.percentLabel(
                walkFinished: walkFinished,
                bytesUploaded: bytesUploaded,
                bytesToUpload: bytesToUpload
            )
        case .finished:
            return "100%"
        default:
            return ""
        }
    }

    /// Single `objectWillChange` for batched counter/path/rate updates.
    private func publishProgress() {
        progressEpoch &+= 1
    }

    func cancel() {
        // The click that starts a run also synthesizes a cancel. Ignore that one.
        guard !suppressCancel else { return }
        task?.cancel()
        task = nil
        if isRunning {
            state = .failed("Cancelled")
            phase = .idle
        }
    }

    /// - Parameter onSourceCompleted: Invoked on the main actor after each source finishes
    ///   successfully (walk + puts + Sync-mode prune). Not called on cancel/fail for that source.
    ///   Multi-source jobs fire once per completed source; earlier sources keep their stamp if a
    ///   later source fails or the job is cancelled.
    func sync(sources: [BackupSource], session: VaultSession, onSourceCompleted: ((String) -> Void)? = nil) {
        task?.cancel()
        task = nil
        runToken &+= 1
        let token = runToken
        suppressCancel = true
        state = .running
        phase = .preparing
        filesDone = 0
        bytesDone = 0
        filesTotal = 0
        bytesTotal = 0
        filesDiscovered = 0
        bytesDiscovered = 0
        filesToUpload = 0
        bytesToUpload = 0
        filesSkipped = 0
        bytesSkipped = 0
        filesUploaded = 0
        bytesUploaded = 0
        filesDeleted = 0
        walkFinished = false
        uploadBytesPerSecond = 0
        progressEpoch = 0
        putRateWindowStartedAt = nil
        putRateWindowBytes = 0
        currentPath = ""
        currentSourceName = sources.first?.vaultFolderName ?? ""
        let transferRunID = TransferMetrics.beginRun()

        // Detached: do not inherit @MainActor for the long upload pipeline
        // (MainActor inheritance serialized prep LIST/UI hops and starved PUT scheduling).
        task = Task.detached { [weak self] in
            guard let self else { return }
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "CryptoMako backup sync"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
                TransferMetrics.endRun(transferRunID)
            }
            do {
                let excludes = BackupSyncExcludesStore.load()
                let bandwidthLimiter = UploadBandwidthLimiter.fromPreferences(AppPreferences.load())
                try Task.checkCancellation()
                // Best-effort reclaim of orphaned encrypt temps from prior killed runs.
                // Age-gated so an in-flight upload (this or another instance) is never deleted.
                // Failures are logged only — never abort a backup. Not in CryptoMakoApp
                // launch hooks (owned by another change); sync-start is the engine-owned site.
                _ = EncryptionTempCleanup.removeStaleOrphans()
                await MainActor.run {
                    self.phase = .preparing
                    self.currentPath = sources.isEmpty
                        ? "No sources"
                        : "Preparing vault folder Backups…"
                }
                Self.syncLog.info("ensureDirectoryPath start path=Backups")
                _ = try await session.ensureDirectoryPath("Backups")
                Self.syncLog.info("ensureDirectoryPath done path=Backups")

                var files = 0
                var bytes: Int64 = 0
                var syncState = try BackupSyncState.load()
                for source in sources {
                    try Task.checkCancellation()
                    let vaultRoot = "Backups/\(source.vaultFolderName)"
                    await MainActor.run {
                        self.currentSourceName = source.vaultFolderName
                        self.walkFinished = false
                        // Stay on Preparing until vault dirs resolve — MinIO LIST can
                        // hang here; do not claim "Walking local tree…" yet.
                        self.phase = .preparing
                        self.currentPath = "Preparing vault folder \(vaultRoot)…"
                    }
                    let root = URL(fileURLWithPath: source.path, isDirectory: true)
                    let isSMB = source.isSMB
                    guard FileManager.default.fileExists(atPath: root.path) else {
                        throw SyncError.missingSource(source.path)
                    }
                    try self.assertSourceStillPresent(
                        path: root.path,
                        isSMB: isSMB,
                        expectedSMBURL: source.smbURL
                    )
                    Self.syncLog.info("ensureDirectoryPath start path=\(vaultRoot, privacy: .private(mask: .hash))")
                    let leafDirId = try await session.ensureDirectoryPath(vaultRoot)
                    Self.syncLog.info("ensureDirectoryPath done path=\(vaultRoot, privacy: .private(mask: .hash))")
                    let transferMode = AppPreferences.load().backupTransferMode
                    let result = try await self.uploadTree(
                        localRoot: root,
                        parentDirId: leafDirId,
                        session: session,
                        sourceID: source.id,
                        transferRunID: transferRunID,
                        vaultFolderName: source.vaultFolderName,
                        syncState: &syncState,
                        excludes: excludes,
                        bandwidthLimiter: bandwidthLimiter,
                        isSMB: isSMB,
                        expectedSMBURL: source.smbURL,
                        transferMode: transferMode
                    )
                    try syncState.save()
                    files += result.files
                    bytes += result.bytes
                    let completedID = source.id
                    await MainActor.run {
                        self.filesDone = self.filesSkipped + self.filesUploaded
                        onSourceCompleted?(completedID)
                    }
                }
                await MainActor.run {
                    guard self.runToken == token else { return }
                    self.phase = .finishing
                    self.filesDone = self.filesSkipped + self.filesUploaded
                    self.currentPath = ""
                    self.currentSourceName = ""
                    self.state = .finished(files: files, bytes: bytes)
                    self.phase = .idle
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.runToken == token else { return }
                    self.state = .failed("Cancelled")
                    self.phase = .idle
                }
            } catch {
                await MainActor.run {
                    guard self.runToken == token else { return }
                    self.state = .failed(error.localizedDescription)
                    self.phase = .idle
                }
            }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.runToken == token else { return }
            self.suppressCancel = false
        }
    }

    private struct Count {
        var files: Int
        var bytes: Int64
    }

    /// Cleartext files larger than this share limited upload slots so we never
    /// hold several multi-GB ciphertext streams at once (file puts stream UNSIGNED-PAYLOAD).
    nonisolated private static let largeFileBytes: Int64 = 32 * 1024 * 1024
    /// Prefer medium+ files on a dedicated pool so millions of tiny puts cannot
    /// monopolize every worker (was burying useful MB-scale uploads).
    nonisolated private static let mediumFileBytes: Int64 = 256 * 1024
    /// Compact per-file upload record produced by the scan; see `BackupScanPlan`.
    private typealias PendingUpload = BackupPendingUpload

    /// Accumulates walk discovery/skip/queue counters without awaiting MainActor.
    /// A timer task publishes snapshots ~0.75s so SMB walks are not starved by
    /// SwiftUI (~40 files / 0.2s MainActor hops were ~100× slower than a plain walk).
    private final class WalkUIPublisher: @unchecked Sendable {
        private let lock = NSLock()
        private var discovered = 0
        private var discoveredBytes: Int64 = 0
        private var skipped = 0
        private var skippedBytes: Int64 = 0
        private var queued = 0
        private var queuedBytes: Int64 = 0
        private var pendingPath: String?
        private var lastPathAt = Date.distantPast
        /// How often currentPath may change (walk hot path).
        private let pathInterval: TimeInterval = 1.0
        /// MainActor publish cadence for counters (coalesced via progressEpoch).
        private let publishInterval: TimeInterval = 1.5

        struct Snapshot: Sendable {
            let discovered: Int
            let discoveredBytes: Int64
            let skipped: Int
            let skippedBytes: Int64
            let queued: Int
            let queuedBytes: Int64
            let path: String?
        }

        func noteDiscovered(bytes: Int64) {
            lock.lock()
            discovered += 1
            discoveredBytes += bytes
            lock.unlock()
        }

        func noteSkipped(bytes: Int64) {
            lock.lock()
            skipped += 1
            skippedBytes += bytes
            lock.unlock()
        }

        func noteQueued(bytes: Int64) {
            lock.lock()
            queued += 1
            queuedBytes += bytes
            lock.unlock()
        }

        /// Throttle path updates to ~1/s so string churn stays off the walk.
        func notePath(_ path: String) {
            lock.lock()
            let now = Date()
            if now.timeIntervalSince(lastPathAt) >= pathInterval {
                pendingPath = path
                lastPathAt = now
            }
            lock.unlock()
        }

        func take() -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard discovered > 0 || skipped > 0 || queued > 0 || pendingPath != nil else {
                return nil
            }
            let snap = Snapshot(
                discovered: discovered,
                discoveredBytes: discoveredBytes,
                skipped: skipped,
                skippedBytes: skippedBytes,
                queued: queued,
                queuedBytes: queuedBytes,
                path: pendingPath
            )
            discovered = 0
            discoveredBytes = 0
            skipped = 0
            skippedBytes = 0
            queued = 0
            queuedBytes = 0
            pendingPath = nil
            return snap
        }

        var intervalNanoseconds: UInt64 {
            UInt64(publishInterval * 1_000_000_000)
        }
    }

    /// Batches MainActor UI hops so 100+ put workers never serialize on
    /// `currentPath` / counters after every object.
    private final class PutUIBatcher: @unchecked Sendable {
        private let lock = NSLock()
        private var files = 0
        private var bytes: Int64 = 0
        private var path: String?
        private var lastFlush = Date.distantPast
        /// Flush every N puts or this many seconds (whichever first).
        /// Paired with progressEpoch so one publish covers the whole batch.
        private let putThreshold = 96
        private let interval: TimeInterval = 1.0

        struct Batch: Sendable {
            let files: Int
            let bytes: Int64
            let path: String?
        }

        func note(path: String, bytes: Int64) -> Batch? {
            lock.lock()
            defer { lock.unlock() }
            files += 1
            self.bytes += bytes
            self.path = path
            let now = Date()
            if files >= putThreshold || now.timeIntervalSince(lastFlush) >= interval {
                return takeLocked(now: now)
            }
            return nil
        }

        func flush() -> Batch? {
            lock.lock()
            defer { lock.unlock() }
            guard files > 0 else { return nil }
            return takeLocked(now: Date())
        }

        private func takeLocked(now: Date) -> Batch {
            let b = Batch(files: files, bytes: bytes, path: path)
            files = 0
            bytes = 0
            lastFlush = now
            return b
        }
    }

    nonisolated private func uploadTree(
        localRoot: URL,
        parentDirId: String,
        session: VaultSession,
        sourceID: String,
        transferRunID: UUID,
        vaultFolderName: String,
        syncState: inout BackupSyncState,
        excludes: BackupSyncExcludes,
        bandwidthLimiter: UploadBandwidthLimiter?,
        isSMB: Bool,
        expectedSMBURL: String?,
        transferMode: AppPreferences.BackupTransferMode
    ) async throws -> Count {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .contentModificationDateKey,
        ]
        try assertSourceStillPresent(
            path: localRoot.path,
            isSMB: isSMB,
            expectedSMBURL: expectedSMBURL
        )
        // Mid-walk probes are wall-clock throttled — per-N-file volume metadata on SMB
        // turned multi-million-file walks into hour-long probe storms.
        var reachabilityGate = BackupWalkReachabilityGate()
        reachabilityGate.markProbed()
        /// Fail-closed: enumerator I/O errors (SMB disconnect, etc.) must not produce
        /// a silent partial tree — Sync prune would then delete vault orphans incorrectly.
        final class EnumerationErrorBox: @unchecked Sendable {
            let lock = NSLock()
            var firstError: Error?
            var count = 0
            func note(_ error: Error) {
                lock.lock()
                if firstError == nil { firstError = error }
                count += 1
                lock.unlock()
            }
            func snapshot() -> (count: Int, first: Error?) {
                lock.lock(); defer { lock.unlock() }
                return (count, firstError)
            }
        }
        let enumerationErrors = EnumerationErrorBox()
        // Sync: never skip hidden entries — prune allow-set is "present on disk"
        // (1.0.9 H1). Backup: skip hidden at the enumerator so SMB does not
        // attribute-fetch .DS_Store / AppleDouble sidecars that are discarded later.
        let rememberLocalPaths = transferMode == .sync
        let enumOptions = BackupScanEnumeratorPolicy.directoryEnumerationOptions(
            isSyncMode: rememberLocalPaths
        )
        guard let enumerator = fm.enumerator(
            at: localRoot,
            includingPropertiesForKeys: keys,
            options: enumOptions,
            errorHandler: { _, error in
                enumerationErrors.note(error)
                // Stop immediately — continuing after a disconnect can yield an empty/partial tree.
                return false
            }
        ) else {
            if isSMB || SMBBackupMount.looksLikeNetworkVolume(localRoot) {
                throw SyncError.volumeLost(localRoot.path)
            }
            return Count(files: 0, bytes: 0)
        }

        /// Sync-mode orphan prune only ("present on disk", including excluded/hidden).
        /// Backup mode must not retain every relative path of a multi-million-file tree.
        var localFiles = Set<String>()
        var scanCompleted = false
        let dirCache = BackupDirectoryResolutionCache(
            rootDirectoryID: parentDirId,
            lookup: { parentID, name in
                try await session.existingDirectoryId(parentDirId: parentID, cleartextName: name)
            },
            create: { parentID, name in
                let created = try await session.createDirectory(
                    parentDirId: parentID,
                    cleartextName: name,
                    skipExistsCheck: true
                )
                return created.dirId ?? ""
            }
        )
        /// Scan output: compact to-upload records + counts. Filled during the scan,
        /// frozen before the first put. Large to-upload sets are retained on purpose
        /// (that is the price of knowing the remaining bytes up front).
        var plan = BackupScanPlan(
            mediumThreshold: Self.mediumFileBytes,
            largeThreshold: Self.largeFileBytes
        )

        let walkUI = WalkUIPublisher()

        func applyWalkSnapshot(_ snap: WalkUIPublisher.Snapshot) async {
            await MainActor.run {
                if snap.discovered > 0 {
                    self.filesDiscovered += snap.discovered
                    self.bytesDiscovered += snap.discoveredBytes
                    self.filesTotal = self.filesDiscovered
                    self.bytesTotal = self.bytesDiscovered
                }
                if snap.queued > 0 {
                    self.filesToUpload += snap.queued
                    self.bytesToUpload += snap.queuedBytes
                }
                if snap.skipped > 0 {
                    self.filesSkipped += snap.skipped
                    self.bytesSkipped += snap.skippedBytes
                    self.filesDone = self.filesSkipped + self.filesUploaded
                    self.bytesDone += snap.skippedBytes
                }
                if let p = snap.path { self.currentPath = p }
                self.publishProgress()
            }
        }

        // First moment we claim Scanning — vault ensureDirectoryPath already done.
        await MainActor.run {
            self.walkFinished = false
            self.phase = .walking
            self.currentPath = "Scanning \(localRoot.path)…"
        }

        // Publish counters on a timer without suspending the walk on MainActor.
        let walkPublishTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: walkUI.intervalNanoseconds)
                if Task.isCancelled { break }
                if let snap = walkUI.take() {
                    await applyWalkSnapshot(snap)
                }
            }
        }
        defer { walkPublishTask.cancel() }

        // Three priority tiers: large / medium / small. Each tier is one bounded
        // TaskGroup (limit = Settings workers for that tier) over its slice of the
        // frozen scan plan. Nothing here starts until the scan has completed.
        let vaultFolder = vaultFolderName
        // Worker counts come from Settings (AppPreferences); clamp fail-closed.
        let syncPrefs = AppPreferences.load()
        let smallWorkers = syncPrefs.clampedSmallPutConcurrency
        let mediumWorkers = syncPrefs.clampedMediumPutConcurrency
        let largeWorkers = syncPrefs.clampedLargePutConcurrency
        let workerCount = smallWorkers + mediumWorkers + largeWorkers
        Self.syncLog.info(
            "put workers small=\(smallWorkers) medium=\(mediumWorkers) large=\(largeWorkers)"
        )

        // Fingerprint index: set/get under a short lock; JSON encode + atomic write
        // run off-lock on a background queue (coalesced). Forced saves are synchronous.
        let box = BackupFingerprintStore(syncState)

        final class UploadCounter: @unchecked Sendable {
            let lock = NSLock()
            var files = 0
            var bytes: Int64 = 0
            func add(fileBytes: Int64) {
                lock.lock(); files += 1; bytes += fileBytes; lock.unlock()
            }
            func snapshot() -> Count {
                lock.lock(); defer { lock.unlock() }
                return Count(files: files, bytes: bytes)
            }
        }
        let counter = UploadCounter()
        let uiBatcher = PutUIBatcher()
        /// Per-file transport failures after S3 retries. Does not cancel sibling puts.
        final class FailureCounter: @unchecked Sendable {
            let lock = NSLock()
            var failedPuts = 0
            var lastDetail: String?
            func note(path: String, detail: String) {
                lock.lock()
                failedPuts += 1
                lastDetail = "\(path): \(detail)"
                lock.unlock()
            }
            func snapshot() -> (count: Int, lastDetail: String?) {
                lock.lock(); defer { lock.unlock() }
                return (failedPuts, lastDetail)
            }
        }
        let putFailures = FailureCounter()

        func applyUIBatch(_ batch: PutUIBatcher.Batch) async {
            await MainActor.run {
                self.filesUploaded += batch.files
                self.bytesUploaded += batch.bytes
                self.filesDone = self.filesSkipped + self.filesUploaded
                self.bytesDone += batch.bytes
                if let p = batch.path { self.currentPath = p }
                self.notePutCommitted(bytes: batch.bytes)
                self.publishProgress()
            }
        }

        // The scan stores only the relative path; rebuild the local URL per put.
        let rootPath = localRoot.path
        func localURL(for job: PendingUpload) -> URL {
            URL(fileURLWithPath: rootPath + "/" + job.relativePath, isDirectory: false)
        }

        func putOne(_ job: PendingUpload) async throws {
            try Task.checkCancellation()
            do {
                // Vault dir resolve (dir.c9r) happens here, in the upload phase only.
                let parentId = try await dirCache.resolve(job.parentRelativePath)
                let fileURL = localURL(for: job)
                // Start the put without waiting for full-file bandwidth tokens (bucket
                // holds only ~1s of rate). Charge after so large files proceed and
                // TransferMetrics.inFlight reflects live createOrOverwrite work.
                _ = try await session.createOrOverwriteFile(
                    parentDirId: parentId,
                    cleartextName: fileURL.lastPathComponent,
                    contentsURL: fileURL,
                    diagnosticPath: job.relativePath,
                    diagnosticSourceID: sourceID,
                    diagnosticRunID: transferRunID
                )
                // Pace Sync puts only (Finder File Provider uses a different path).
                if let limiter = bandwidthLimiter {
                    await limiter.acquire(job.size)
                }
                let key = BackupSyncState.key(
                    vaultFolder: vaultFolder,
                    relativePath: job.relativePath
                )
                let fp = BackupFileFingerprint(
                    size: job.size,
                    contentModification: job.contentModification
                )
                box.set(key, fp)
                counter.add(fileBytes: job.size)
                if box.notePutCommittedForPersist() {
                    try box.save()
                }
                if let batch = uiBatcher.note(path: job.relativePath, bytes: job.size) {
                    await applyUIBatch(batch)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if Self.isIsolatablePutTransportFailure(error) {
                    let detail = error.localizedDescription
                    Self.syncLog.error(
                        "put isolated transport failure path=\(job.relativePath, privacy: .private(mask: .hash)) err=\(detail, privacy: .private(mask: .hash))"
                    )
                    putFailures.note(path: job.relativePath, detail: detail)
                    return
                }
                // Auth, vault crypto, volume/config, and other hard errors fail closed
                // (rethrow → TaskGroup cancels siblings).
                throw error
            }
        }

        /// One tier: bounded TaskGroup over that tier's slice of the frozen plan
        /// (limit = Settings workers for the tier). Called only after the scan.
        func drainTier(
            jobs: [PendingUpload],
            limit: Int,
            label: String
        ) async throws {
            guard !jobs.isEmpty else { return }
            try await withThrowingTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for job in jobs {
                    try Task.checkCancellation()
                    if inFlight >= limit {
                        try await group.next()
                        inFlight -= 1
                    }
                    inFlight += 1
                    group.addTask {
                        try await putOne(job)
                    }
                }
                try await group.waitForAll()
            }
            Self.syncLog.info("drainTier done tier=\(label) limit=\(limit) jobs=\(jobs.count)")
        }

        /// Upload phase. Precondition: `plan.isFinished` — the scan completed and the
        /// source was still reachable. Never runs concurrently with the enumerator.
        func uploadPlanned(_ plan: BackupScanPlan) async throws -> Count {
            precondition(plan.isFinished, "upload phase started before the scan finished")
            Self.syncLog.info(
                "upload phase start toUploadFiles=\(plan.toUpload.files) toUploadBytes=\(plan.toUpload.bytes) small=\(plan.small.count)/\(smallWorkers) medium=\(plan.medium.count)/\(mediumWorkers) large=\(plan.large.count)/\(largeWorkers) workers=\(workerCount)"
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await drainTier(jobs: plan.small, limit: smallWorkers, label: "small")
                }
                group.addTask {
                    try await drainTier(jobs: plan.medium, limit: mediumWorkers, label: "medium")
                }
                group.addTask {
                    try await drainTier(jobs: plan.large, limit: largeWorkers, label: "large")
                }
                try await group.waitForAll()
            }
            if let batch = uiBatcher.flush() {
                await applyUIBatch(batch)
            }
            let snap = counter.snapshot()
            let failures = putFailures.snapshot()
            Self.syncLog.info(
                "upload phase done files=\(snap.files) bytes=\(snap.bytes) failedPuts=\(failures.count)"
            )
            if failures.count > 0 {
                throw SyncError.putFailures(count: failures.count, detail: failures.lastDetail)
            }
            return snap
        }

        // ---- Phase 1: scan -------------------------------------------------------
        // Local enumeration only: prefetched size/mtime + fingerprint index.
        // Never LIST the vault, resolve dir.c9r, save the index, start a put, or
        // wait on anything network-bound on this thread. Unchanged → skip (not
        // retained). New or changed → compact record in `plan`.
        // `resourceValues` reads the cache filled by `includingPropertiesForKeys`
        // (same keys as the fast walk). Do not allocate that set per entry, and no
        // per-file standardizedFileURL (SMB-expensive).
        let prefetchedKeys = Set(keys)
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            if reachabilityGate.shouldProbe() {
                try assertSourceStillPresent(
                    path: localRoot.path,
                    isSMB: isSMB,
                    expectedSMBURL: expectedSMBURL
                )
            }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: prefetchedKeys)
            } catch {
                try assertSourceStillPresent(
                    path: localRoot.path,
                    isSMB: isSMB,
                    expectedSMBURL: expectedSMBURL
                )
                throw SyncError.volumeLost(localRoot.path)
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                let dirName = fileURL.lastPathComponent
                let dirHidden = dirName.hasPrefix(".") || values.isHidden == true
                let dirExcluded = excludes.shouldSkipDirectory(named: dirName)
                // Backup: skip excluded/hidden trees (no prune allow-set).
                // Sync: keep walking so nested files are recorded as present (not uploaded).
                if (dirHidden || dirExcluded) && !rememberLocalPaths {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let name = fileURL.lastPathComponent
            let rel: String
            do {
                rel = try BackupRelativePath.make(filePath: fileURL.path, rootPath: rootPath)
            } catch {
                throw SyncError.pathOutsideSource(fileURL.path)
            }
            let isHidden = name.hasPrefix(".") || values.isHidden == true
            let isExcluded = excludes.shouldSkipFile(named: name)
                || excludes.shouldSkipRelativePath(rel)
            let disposition = BackupSyncPresentSetPolicy.disposition(
                isHidden: isHidden,
                isExcluded: isExcluded
            )
            if BackupSyncPresentSetPolicy.retainInPruneAllowSet(
                isSyncMode: rememberLocalPaths,
                pathPresentOnDisk: true
            ) {
                localFiles.insert(rel)
            }
            // Excluded / hidden: present for prune, never uploaded.
            guard disposition == .presentUploadEligible else { continue }

            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date.distantPast
            let stateKey = BackupSyncState.key(vaultFolder: vaultFolderName, relativePath: rel)

            walkUI.noteDiscovered(bytes: size)
            walkUI.notePath(rel)

            // Pure decision + compact record. Skip does not probe, list, or save.
            switch plan.record(
                relativePath: rel,
                size: size,
                contentModification: mtime,
                indexed: box.get(stateKey)
            ) {
            case .skipUnchanged:
                walkUI.noteSkipped(bytes: size)
            case .enqueueUpload:
                walkUI.noteQueued(bytes: size)
            }
        }
        plan.finish()

        walkPublishTask.cancel()
        if let snap = walkUI.take() {
            await applyWalkSnapshot(snap)
        }
        // Mandatory post-scan probe (not gated) — never treat a disconnected share
        // as an empty-tree success before uploads start or Sync prune runs.
        try assertSourceStillPresent(
            path: localRoot.path,
            isSMB: isSMB,
            expectedSMBURL: expectedSMBURL
        )
        let enumSnap = enumerationErrors.snapshot()
        if enumSnap.count > 0 {
            let detail = enumSnap.first.map { $0.localizedDescription } ?? "unknown"
            Self.syncLog.error(
                "scan aborted errors=\(enumSnap.count) detail=\(detail, privacy: .private(mask: .hash))"
            )
            // Failed scan: no uploads, no prune.
            throw SyncError.enumerationFailed(localRoot.path)
        }
        scanCompleted = true
        let skipped = Count(files: plan.skipped.files, bytes: plan.skipped.bytes)
        let toUpload = plan.toUpload
        Self.syncLog.info(
            "scan done discovered=\(plan.discovered.files) skipped=\(skipped.files) toUploadFiles=\(toUpload.files) toUploadBytes=\(toUpload.bytes) localFilesRetained=\(localFiles.count)"
        )
        // Scan complete: the UI now shows the exact files/bytes still to transfer
        // before the first put starts.
        await MainActor.run {
            self.walkFinished = true
            self.phase = .uploading
            self.currentPath = toUpload.files == 0
                ? "Scan complete — nothing to upload."
                : "Scan complete — \(toUpload.files.formatted()) files, \(TransferSnapshot.formatBytes(toUpload.bytes)) to upload…"
            self.publishProgress()
        }

        // ---- Phase 2: upload -----------------------------------------------------
        let uploaded: Count
        do {
            uploaded = try await uploadPlanned(plan)
            try box.save(force: true)
        } catch let primary {
            // A cancellation or put failure still gets one synchronous durability
            // attempt. If that save also fails, surface BOTH (combined error) so
            // index corruption is never silently dropped behind the upload error.
            var saveFailure: Error?
            do {
                try box.save(force: true)
            } catch {
                saveFailure = error
                Self.syncLog.error(
                    "backup index durability save failed after sync error save=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            throw BackupPostFailureSavePolicy.errorToThrow(
                primary: primary,
                saveFailure: saveFailure
            )
        }
        try assertSourceStillPresent(
            path: localRoot.path,
            isSMB: isSMB,
            expectedSMBURL: expectedSMBURL
        )
        syncState = box.snapshot()

        if transferMode == .sync {
            guard BackupPruneIndex.shouldPrune(scanCompleted: scanCompleted) else {
                throw SyncError.enumerationFailed(localRoot.path)
            }
            // Mandatory pre-prune probe — fail closed before deleting vault orphans.
            try assertSourceStillPresent(
                path: localRoot.path,
                isSMB: isSMB,
                expectedSMBURL: expectedSMBURL
            )
            await MainActor.run {
                self.phase = .pruning
                self.currentPath = "Comparing vault Backups/\(vaultFolderName)/ to local tree…"
            }
            Self.syncLog.info(
                "sync orphan prune start vaultFolder=\(vaultFolderName, privacy: .private(mask: .hash)) localFiles=\(localFiles.count)"
            )
            let deleted = try await deleteVaultOrphans(
                session: session,
                rootDirId: parentDirId,
                localFiles: localFiles,
                vaultFolderName: vaultFolderName,
                syncState: &syncState
            )
            try syncState.save()
            await MainActor.run {
                self.filesDeleted += deleted
                self.publishProgress()
            }
            Self.syncLog.info(
                "sync orphan prune done vaultFolder=\(vaultFolderName, privacy: .private(mask: .hash)) deleted=\(deleted)"
            )
        } else {
            try syncState.save()
        }

        return Count(files: skipped.files + uploaded.files, bytes: skipped.bytes + uploaded.bytes)
    }

    /// Sync mode only: delete remote ciphertext under this source’s vault folder that
    /// has no matching local path present on disk (including excluded/hidden locals).
    /// Never touches the local source tree.
    /// Fail-closed: ObjectStore/`VaultSession` delete errors abort the run.
    nonisolated private func deleteVaultOrphans(
        session: VaultSession,
        rootDirId: String,
        localFiles: Set<String>,
        vaultFolderName: String,
        syncState: inout BackupSyncState
    ) async throws -> Int {
        let pruneIndex = BackupPruneIndex(localFiles: localFiles)
        var deletedFiles = Set<String>()
        var deletedDirectories = Set<String>()

        final class PathPublishGate: @unchecked Sendable {
            private let lock = NSLock()
            private var lastPublish = Date.distantPast

            func shouldPublish(now: Date = Date()) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard now.timeIntervalSince(lastPublish) >= 0.1 else { return false }
                lastPublish = now
                return true
            }
        }
        let pathPublishGate = PathPublishGate()

        func prune(dirId: String, relPrefix: String) async throws -> Int {
            try Task.checkCancellation()
            let children = try await session.list(dirId: dirId)
            var deleted = 0
            for child in children {
                try Task.checkCancellation()
                let childRel = relPrefix.isEmpty
                    ? child.cleartextName
                    : relPrefix + "/" + child.cleartextName
                if pathPublishGate.shouldPublish() {
                    await MainActor.run {
                        self.currentPath = childRel
                    }
                }
                switch child.kind {
                case .file, .symlink:
                    if !pruneIndex.containsFile(childRel) {
                        // Remote ObjectStore ciphertext delete only — never local source.
                        try await session.deleteFile(node: child)
                        deletedFiles.insert(childRel)
                        deleted += 1
                    }
                case .directory:
                    guard let childDirId = child.dirId else { continue }
                    if !pruneIndex.hasLocalUnder(childRel) {
                        // Entire subtree is vault-only under this source folder.
                        try await session.deleteDirectory(node: child, recursive: true)
                        deletedDirectories.insert(childRel)
                        deleted += 1
                    } else {
                        deleted += try await prune(dirId: childDirId, relPrefix: childRel)
                    }
                }
            }
            return deleted
        }

        let deleted = try await prune(dirId: rootDirId, relPrefix: "")
        let victims = BackupPruneStateRemoval.keysToRemove(
            from: syncState.files.keys,
            vaultFolderName: vaultFolderName,
            deletedFiles: deletedFiles,
            deletedDirectories: deletedDirectories
        )
        for key in victims {
            syncState.files.removeValue(forKey: key)
        }
        return deleted
    }

    /// Update job BW from cleartext bytes just committed via remote put (not skips).
    private func notePutCommitted(bytes: Int64) {
        let now = Date()
        if putRateWindowStartedAt == nil {
            putRateWindowStartedAt = now
            putRateWindowBytes = 0
        }
        putRateWindowBytes += max(0, bytes)
        if let started = putRateWindowStartedAt {
            let dt = now.timeIntervalSince(started)
            if dt >= 0.35, putRateWindowBytes > 0 {
                let rate = Double(putRateWindowBytes) / max(dt, 0.001)
                uploadBytesPerSecond = uploadBytesPerSecond == 0
                    ? rate
                    : (uploadBytesPerSecond * 0.7 + rate * 0.3)
                putRateWindowStartedAt = now
                putRateWindowBytes = 0
            }
        }
    }

    enum SyncError: LocalizedError {
        case missingSource(String)
        case missingParent(String)
        case volumeLost(String)
        /// Enumerator reported I/O errors (e.g. SMB disconnect). Tree may be partial —
        /// abort before Sync prune can treat unseen locals as vault orphans.
        case enumerationFailed(String)
        /// File URL is not under the source root — fail closed (no lastPathComponent fallback).
        case pathOutsideSource(String)
        /// One or more file puts failed after S3 retries; siblings were not cancelled.
        case putFailures(count: Int, detail: String?)
        var errorDescription: String? {
            switch self {
            case .missingSource(let p):
                return "Source folder missing: \(p). Sync stopped fail-closed (not treated as an empty tree)."
            case .missingParent(let p):
                return "Parent folder not registered for \(p)"
            case .volumeLost(let p):
                return "Backup source volume disappeared during Sync: \(p). Sync stopped fail-closed (no wipe / no silent empty-tree success)."
            case .enumerationFailed(let p):
                return "Could not finish reading backup source \(p). Sync stopped fail-closed (incomplete tree — nothing pruned)."
            case .pathOutsideSource(let p):
                return "Backup scan found a path outside the source root: \(p). Sync stopped fail-closed."
            case .putFailures(let count, let detail):
                let suffix = detail.map { " Last: \($0)" } ?? ""
                return "\(count) file(s) failed to upload after retries (network). Other files completed; retry Sync for the rest.\(suffix)"
            }
        }
    }

    /// Transport failures that should not cancel sibling puts in `drainTier`.
    /// Distinguished from user Cancel (`CancellationError` / URLError.cancelled) and
    /// hard vault/auth/config errors (those still fail closed via rethrow).
    nonisolated private static func isIsolatablePutTransportFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            return false
        }
        if let store = error as? ObjectStoreError {
            switch store {
            case .transport(let message):
                // HTTP 403 from S3ObjectStore.check — auth, fail closed.
                let lower = message.lowercased()
                if lower.contains("access denied") || lower.contains("http 403") {
                    return false
                }
                return true
            case .notFound:
                return false
            }
        }
        if let vault = error as? VaultError {
            switch vault {
            case .store(let store):
                return isIsolatablePutTransportFailure(store)
            default:
                return false
            }
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet:
                return true
            default:
                break
            }
        }
        return false
    }

    /// Fail-closed: SMB / network volumes must stay mounted for the whole Sync.
    nonisolated private func assertSourceStillPresent(
        path: String,
        isSMB: Bool,
        expectedSMBURL: String?
    ) throws {
        do {
            try SMBBackupMount.assertSourceReachable(
                path: path,
                isSMB: isSMB,
                expectedSMBURL: expectedSMBURL
            )
        } catch {
            throw SyncError.volumeLost(path)
        }
    }
}
