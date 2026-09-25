import CryptoMakoShared
import CryptoMakoVault
import Foundation
import OSLog

/// Walks picked local folders and writes into the vault via `VaultSession`
/// (encrypt + remote put per file). Directories stay ordered; file puts run with
/// bounded parallelism (many small files, few large) to fill the network pipe.
///
/// Single local walk per source: discover → exclude → skip unchanged / already-in-vault
/// → enqueue puts. Progress denominator grows with discovery; numerator is
/// skipped + uploaded (no separate pre-scan enumeration).
///
/// Transfer mode (`AppPreferences.backupTransferMode`):
/// - **backup** (default): put/update only. Never deletes the local source. Never
///   deletes vault extras missing from source.
/// - **sync**: same puts, then delete remote ciphertext under `Backups/<folder>/`
///   that is missing from the local tree (ObjectStore delete, fail-closed). Never
///   deletes the local source. Scope is that source’s vault folder only.
@MainActor
final class BackupSyncEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(files: Int, bytes: Int64)
        case failed(String)
    }

    /// Coarse UI phase for Backup Sync (walk and upload can overlap briefly).
    enum Phase: String, Equatable {
        case idle = ""
        case preparing = "Preparing sources…"
        case walking = "Walking local tree…"
        case skipping = "Skipping unchanged…"
        case queuing = "Queuing uploads…"
        case uploading = "Uploading to vault…"
        case pruning = "Removing vault-only files…"
        case finishing = "Finishing…"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentPath: String = ""
    @Published private(set) var currentSourceName: String = ""
    /// Skipped + uploaded (progress numerator).
    @Published private(set) var filesDone: Int = 0
    @Published private(set) var bytesDone: Int64 = 0
    /// Files discovered so far (progress denominator; freezes when walk finishes).
    @Published private(set) var filesTotal: Int = 0
    @Published private(set) var bytesTotal: Int64 = 0
    /// Eligible files seen during the single walk (same as `filesTotal` while running).
    @Published private(set) var filesDiscovered: Int = 0
    @Published private(set) var bytesDiscovered: Int64 = 0
    /// Files enqueued for remote put (not skipped).
    @Published private(set) var filesQueued: Int = 0
    /// Files skipped because unchanged (local index) or already present in the vault.
    @Published private(set) var filesSkipped: Int = 0
    /// Completed remote puts (cleartext bytes also in `bytesUploaded`).
    @Published private(set) var filesUploaded: Int = 0
    @Published private(set) var bytesUploaded: Int64 = 0
    /// Vault ciphertext files removed in Sync mode (orphan prune). Always 0 in Backup mode.
    @Published private(set) var filesDeleted: Int = 0
    /// True after the local enumerator finishes feeding the put streams for the
    /// current source (totals for that source stop growing; queue drains).
    @Published private(set) var walkFinished: Bool = false
    /// Job upload rate (cleartext bytes committed in the put phase only; skips excluded).
    @Published private(set) var uploadBytesPerSecond: Double = 0

    /// Primary status line for the Backup UI.
    var phaseLabel: String { phase.rawValue }

    nonisolated private static let syncLog = Logger(subsystem: "net.gschimmel.cryptomako", category: "backup-sync")

    private var task: Task<Void, Never>?
    private var putRateWindowStartedAt: Date?
    private var putRateWindowBytes: Int64 = 0

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// 0…1 based on (skipped+uploaded) / discovered. Totals grow during the walk.
    var progressFraction: Double {
        switch state {
        case .running, .finished:
            if bytesTotal > 0 {
                return min(1, Double(bytesDone) / Double(bytesTotal))
            }
            if filesTotal > 0 {
                return min(1, Double(filesDone) / Double(filesTotal))
            }
            return 0
        default:
            return 0
        }
    }

    var progressPercentLabel: String {
        let pct = Int((progressFraction * 100).rounded(.down))
        switch state {
        case .running:
            if filesTotal > 0 || bytesTotal > 0 {
                return "\(pct)%"
            }
            return "…"
        case .finished:
            return "100%"
        default:
            return ""
        }
    }

    func cancel() {
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
        cancel()
        state = .running
        phase = .preparing
        filesDone = 0
        bytesDone = 0
        filesTotal = 0
        bytesTotal = 0
        filesDiscovered = 0
        bytesDiscovered = 0
        filesQueued = 0
        filesSkipped = 0
        filesUploaded = 0
        bytesUploaded = 0
        filesDeleted = 0
        walkFinished = false
        uploadBytesPerSecond = 0
        putRateWindowStartedAt = nil
        putRateWindowBytes = 0
        currentPath = ""
        currentSourceName = sources.first?.vaultFolderName ?? ""

        // Detached: do not inherit @MainActor for the long upload pipeline
        // (MainActor inheritance serialized prep LIST/UI hops and starved PUT scheduling).
        task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let excludes = BackupSyncExcludesStore.load()
                let bandwidthLimiter = UploadBandwidthLimiter.fromPreferences(AppPreferences.load())
                try Task.checkCancellation()
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
                var syncState = BackupSyncState.load()
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
                    try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
                    Self.syncLog.info("ensureDirectoryPath start path=\(vaultRoot, privacy: .public)")
                    let leafDirId = try await session.ensureDirectoryPath(vaultRoot)
                    Self.syncLog.info("ensureDirectoryPath done path=\(vaultRoot, privacy: .public)")
                    let transferMode = AppPreferences.load().backupTransferMode
                    let result = try await self.uploadTree(
                        localRoot: root,
                        parentDirId: leafDirId,
                        session: session,
                        vaultFolderName: source.vaultFolderName,
                        syncState: &syncState,
                        excludes: excludes,
                        bandwidthLimiter: bandwidthLimiter,
                        isSMB: isSMB,
                        transferMode: transferMode
                    )
                    syncState.save()
                    files += result.files
                    bytes += result.bytes
                    let completedID = source.id
                    await MainActor.run {
                        self.filesDone = self.filesSkipped + self.filesUploaded
                        onSourceCompleted?(completedID)
                    }
                }
                await MainActor.run {
                    self.phase = .finishing
                    self.filesDone = self.filesSkipped + self.filesUploaded
                    self.currentPath = ""
                    self.currentSourceName = ""
                    self.state = .finished(files: files, bytes: bytes)
                    self.phase = .idle
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.state = .failed("Cancelled")
                    self.phase = .idle
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                    self.phase = .idle
                }
            }
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
    private struct PendingUpload: Sendable {
        /// Relative folder under the source root ("" = vault source root). Resolved
        /// in put workers — never on the walk thread — so dir.c9r GETs cannot starve
        /// the job stream.
        let parentRel: String
        let fileURL: URL
        let relativePath: String
        let size: Int64
        let contentModification: Date
    }

    /// Shared vault-dir cache. Actor-serialized so parallel put workers never
    /// race `createDirectory` for the same cleartext path (duplicate dirIds).
    private actor DirIdCache {
        private var dirIds: [String: String]
        private let rootDirId: String
        private let session: VaultSession

        init(rootDirId: String, session: VaultSession) {
            self.rootDirId = rootDirId
            self.session = session
            self.dirIds = ["": rootDirId]
        }

        func resolve(_ relFolder: String) async throws -> String {
            let key = relFolder == "." ? "" : relFolder
            if let hit = dirIds[key] { return hit }
            if key.isEmpty { return rootDirId }
            let parts = key.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            var parentId = rootDirId
            var built = ""
            for part in parts {
                built = built.isEmpty ? part : built + "/" + part
                if let hit = dirIds[built] {
                    parentId = hit
                    continue
                }
                let dirId: String
                if let existing = try await session.existingDirectoryId(
                    parentDirId: parentId,
                    cleartextName: part
                ) {
                    dirId = existing
                } else {
                    let created = try await session.createDirectory(
                        parentDirId: parentId,
                        cleartextName: part,
                        skipExistsCheck: true
                    )
                    dirId = created.dirId ?? ""
                }
                dirIds[built] = dirId
                parentId = dirId
            }
            return parentId
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
        private let putThreshold = 48
        private let interval: TimeInterval = 0.35

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
        vaultFolderName: String,
        syncState: inout BackupSyncState,
        excludes: BackupSyncExcludes,
        bandwidthLimiter: UploadBandwidthLimiter?,
        isSMB: Bool,
        transferMode: AppPreferences.BackupTransferMode
    ) async throws -> Count {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        guard let enumerator = fm.enumerator(
            at: localRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            if isSMB || SMBBackupMount.looksLikeNetworkVolume(localRoot) {
                throw SyncError.volumeLost(localRoot.path)
            }
            return Count(files: 0, bytes: 0)
        }

        var fileNameCache: [String: Set<String>] = [:]
        /// Eligible local relative paths (post-exclude). Used by Sync-mode orphan prune.
        var localFiles = Set<String>()
        var skipped = Count(files: 0, bytes: 0)
        var sinceSave = 0
        var discoveredSinceUI = 0
        var skippedSinceUI = 0
        var skippedBytesSinceUI: Int64 = 0
        var queuedSinceUI = 0
        var discoveredBytesSinceUI: Int64 = 0
        var lastUI = Date()
        let dirCache = DirIdCache(rootDirId: parentDirId, session: session)

        func cachedFileNames(_ dirId: String) async throws -> Set<String> {
            if let hit = fileNameCache[dirId] { return hit }
            let names = try await session.listFileNames(dirId: dirId)
            fileNameCache[dirId] = names
            return names
        }

        enum WalkUIHint: Sendable {
            case walking
            case skipping
            case queuing
        }

        func flushUI(force: Bool, path: String?, hint: WalkUIHint) async {
            let now = Date()
            guard force
                    || discoveredSinceUI + skippedSinceUI + queuedSinceUI >= 40
                    || now.timeIntervalSince(lastUI) >= 0.2
            else { return }
            let d = discoveredSinceUI
            let db = discoveredBytesSinceUI
            let s = skippedSinceUI
            let sb = skippedBytesSinceUI
            let q = queuedSinceUI
            let p = path
            let h = hint
            discoveredSinceUI = 0
            discoveredBytesSinceUI = 0
            skippedSinceUI = 0
            skippedBytesSinceUI = 0
            queuedSinceUI = 0
            lastUI = now
            await MainActor.run {
                if d > 0 {
                    self.filesDiscovered += d
                    self.bytesDiscovered += db
                    self.filesTotal = self.filesDiscovered
                    self.bytesTotal = self.bytesDiscovered
                }
                if q > 0 { self.filesQueued += q }
                if s > 0 {
                    self.filesSkipped += s
                    self.filesDone = self.filesSkipped + self.filesUploaded
                    self.bytesDone += sb
                }
                if let p { self.currentPath = p }
                // Prefer a stable primary label while walking; refine when useful.
                if !self.walkFinished {
                    switch h {
                    case .skipping:
                        self.phase = .skipping
                    case .queuing:
                        self.phase = .queuing
                    case .walking:
                        self.phase = .walking
                    }
                }
            }
        }

        // First moment we claim Walking — vault ensureDirectoryPath already done.
        await MainActor.run {
            self.walkFinished = false
            self.phase = .walking
            self.currentPath = "Walking \(localRoot.path)…"
        }

        // Three priority streams: large / medium / small. Walk yields without
        // awaiting MinIO so the buffers fill from local disk; put drainers
        // resolve vault dirs and PUT. Each stream has exactly ONE consumer that
        // spawns a bounded TaskGroup (limit = Settings workers for that tier).
        // Previous design ran N `for await` workers on the same AsyncStream —
        // AsyncStream is single-consumer, so put concurrency collapsed (~1)
        // despite small/medium/large worker knobs.
        let (largeStream, largeCont) = AsyncStream.makeStream(
            of: PendingUpload.self,
            bufferingPolicy: .unbounded
        )
        let (mediumStream, mediumCont) = AsyncStream.makeStream(
            of: PendingUpload.self,
            bufferingPolicy: .unbounded
        )
        let (smallStream, smallCont) = AsyncStream.makeStream(
            of: PendingUpload.self,
            bufferingPolicy: .unbounded
        )
        let vaultFolder = vaultFolderName
        let largeThreshold = Self.largeFileBytes
        let mediumThreshold = Self.mediumFileBytes
        // Worker counts come from Settings (AppPreferences); clamp fail-closed.
        let syncPrefs = AppPreferences.load()
        let smallWorkers = syncPrefs.clampedSmallPutConcurrency
        let mediumWorkers = syncPrefs.clampedMediumPutConcurrency
        let largeWorkers = syncPrefs.clampedLargePutConcurrency
        let workerCount = smallWorkers + mediumWorkers + largeWorkers
        Self.syncLog.info(
            "put workers small=\(smallWorkers) medium=\(mediumWorkers) large=\(largeWorkers)"
        )

        final class StateBox: @unchecked Sendable {
            let lock = NSLock()
            var files: [String: BackupFileFingerprint]
            /// Puts since last persist (skip path has its own counter).
            var putsSinceSave = 0
            init(_ state: BackupSyncState) { self.files = state.files }
            func snapshot() -> BackupSyncState {
                lock.lock(); defer { lock.unlock() }
                return BackupSyncState(files: files)
            }
            func set(_ key: String, _ fp: BackupFileFingerprint) {
                lock.lock(); files[key] = fp; lock.unlock()
            }
            func get(_ key: String) -> BackupFileFingerprint? {
                lock.lock(); defer { lock.unlock() }
                return files[key]
            }
            func save() { snapshot().save() }
            /// Persist after successful puts so a crash mid-drain does not
            /// re-upload everything already committed. Returns true when a
            /// save should run (caller saves outside the lock).
            func notePutCommittedForPersist(every: Int = 64) -> Bool {
                lock.lock()
                putsSinceSave += 1
                let should = putsSinceSave >= every
                if should { putsSinceSave = 0 }
                lock.unlock()
                return should
            }
        }
        let box = StateBox(syncState)
        let bootstrapRemoteSkip = syncState.files.isEmpty

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

        func applyUIBatch(_ batch: PutUIBatcher.Batch) async {
            await MainActor.run {
                self.filesUploaded += batch.files
                self.bytesUploaded += batch.bytes
                self.filesDone = self.filesSkipped + self.filesUploaded
                self.bytesDone += batch.bytes
                if let p = batch.path { self.currentPath = p }
                if self.walkFinished {
                    self.phase = .uploading
                }
                self.notePutCommitted(bytes: batch.bytes)
            }
        }

        func putOne(_ job: PendingUpload) async throws {
            try Task.checkCancellation()
            let parentId = try await dirCache.resolve(job.parentRel)
            // Start the put without waiting for full-file bandwidth tokens (bucket
            // holds only ~1s of rate). Charge after so large files proceed and
            // TransferMetrics.inFlight reflects live createOrOverwrite work.
            _ = try await session.createOrOverwriteFile(
                parentDirId: parentId,
                cleartextName: job.fileURL.lastPathComponent,
                contentsURL: job.fileURL
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
                box.save()
            }
            if let batch = uiBatcher.note(path: job.relativePath, bytes: job.size) {
                await applyUIBatch(batch)
            }
        }

        /// Single AsyncStream consumer + bounded TaskGroup. Spawning N
        /// `for await` on one stream does not fan out (single-consumer API).
        func drainTier(
            stream: AsyncStream<PendingUpload>,
            limit: Int,
            label: String
        ) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for await job in stream {
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
            Self.syncLog.info("drainTier done tier=\(label) limit=\(limit)")
        }

        async let uploadResult: Count = {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await drainTier(stream: smallStream, limit: smallWorkers, label: "small")
                }
                group.addTask {
                    try await drainTier(stream: mediumStream, limit: mediumWorkers, label: "medium")
                }
                group.addTask {
                    try await drainTier(stream: largeStream, limit: largeWorkers, label: "large")
                }
                Self.syncLog.info(
                    "uploadPending tier drainers start small=\(smallWorkers) medium=\(mediumWorkers) large=\(largeWorkers) total=\(workerCount)"
                )
                try await group.waitForAll()
            }
            if let batch = uiBatcher.flush() {
                await applyUIBatch(batch)
            }
            let snap = counter.snapshot()
            Self.syncLog.info("uploadPending done files=\(snap.files) bytes=\(snap.bytes)")
            return snap
        }()

        // Single local walk: disk only. Unchanged → skip. New/changed → enqueue
        // without waiting for MinIO (dir resolve happens in put workers).
        var sinceVolumeCheck = 0
        var lastHint: WalkUIHint = .walking
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            sinceVolumeCheck += 1
            if sinceVolumeCheck >= 200 {
                sinceVolumeCheck = 0
                try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
            }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: Set(keys))
            } catch {
                try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
                throw SyncError.volumeLost(localRoot.path)
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if excludes.shouldSkipDirectory(named: fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let name = fileURL.lastPathComponent
            if excludes.shouldSkipFile(named: name) { continue }
            let rel = relativePath(fileURL, under: localRoot)
            if excludes.shouldSkipRelativePath(rel) { continue }

            localFiles.insert(rel)

            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date.distantPast
            let stateKey = BackupSyncState.key(vaultFolder: vaultFolderName, relativePath: rel)
            let fingerprint = BackupFileFingerprint(size: size, contentModification: mtime)

            discoveredSinceUI += 1
            discoveredBytesSinceUI += size

            if box.get(stateKey)?.matches(size: size, contentModification: mtime) == true {
                skipped.files += 1
                skipped.bytes += size
                sinceSave += 1
                skippedSinceUI += 1
                skippedBytesSinceUI += size
                lastHint = .skipping
                await flushUI(force: false, path: rel, hint: .skipping)
                if sinceSave >= 500 {
                    box.save()
                    sinceSave = 0
                }
                continue
            }

            // Bootstrap LIST only when the local index is empty (first sync).
            // Needs a dirId — resolve here only on cold index (rare after first run).
            if box.get(stateKey) == nil, bootstrapRemoteSkip {
                let parentRel = (rel as NSString).deletingLastPathComponent
                let parentKey = parentRel == "." ? "" : parentRel
                let parentId = try await dirCache.resolve(parentKey)
                let remoteNames = try await cachedFileNames(parentId)
                if remoteNames.contains(name) {
                    box.set(stateKey, fingerprint)
                    skipped.files += 1
                    skipped.bytes += size
                    sinceSave += 1
                    skippedSinceUI += 1
                    skippedBytesSinceUI += size
                    lastHint = .skipping
                    await flushUI(force: false, path: rel, hint: .skipping)
                    if sinceSave >= 500 {
                        box.save()
                        sinceSave = 0
                    }
                    continue
                }
            }

            let parentRelRaw = (rel as NSString).deletingLastPathComponent
            let parentRel = parentRelRaw == "." ? "" : parentRelRaw
            let job = PendingUpload(
                parentRel: parentRel,
                fileURL: fileURL,
                relativePath: rel,
                size: size,
                contentModification: mtime
            )
            if size >= largeThreshold {
                largeCont.yield(job)
            } else if size >= mediumThreshold {
                mediumCont.yield(job)
            } else {
                smallCont.yield(job)
            }
            queuedSinceUI += 1
            lastHint = .queuing
            await flushUI(force: false, path: rel, hint: .queuing)
        }

        largeCont.finish()
        mediumCont.finish()
        smallCont.finish()
        await flushUI(force: true, path: nil, hint: lastHint)
        box.save()
        try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        await MainActor.run {
            self.walkFinished = true
            self.phase = .uploading
            self.currentPath = "Uploading remaining files to vault…"
        }

        let uploaded = try await uploadResult
        try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        syncState = box.snapshot()

        if transferMode == .sync {
            await MainActor.run {
                self.phase = .pruning
                self.currentPath = "Comparing vault Backups/\(vaultFolderName)/ to local tree…"
            }
            Self.syncLog.info(
                "sync orphan prune start vaultFolder=\(vaultFolderName, privacy: .public) localFiles=\(localFiles.count)"
            )
            let deleted = try await deleteVaultOrphans(
                session: session,
                rootDirId: parentDirId,
                localFiles: localFiles,
                vaultFolderName: vaultFolderName,
                syncState: &syncState
            )
            syncState.save()
            await MainActor.run {
                self.filesDeleted += deleted
            }
            Self.syncLog.info(
                "sync orphan prune done vaultFolder=\(vaultFolderName, privacy: .public) deleted=\(deleted)"
            )
            try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        } else {
            syncState.save()
        }

        return Count(files: skipped.files + uploaded.files, bytes: skipped.bytes + uploaded.bytes)
    }

    /// Sync mode only: delete remote ciphertext under this source’s vault folder that
    /// has no matching eligible local file. Never touches the local source tree.
    /// Fail-closed: ObjectStore/`VaultSession` delete errors abort the run.
    nonisolated private func deleteVaultOrphans(
        session: VaultSession,
        rootDirId: String,
        localFiles: Set<String>,
        vaultFolderName: String,
        syncState: inout BackupSyncState
    ) async throws -> Int {
        func hasLocalUnder(_ relDir: String) -> Bool {
            // Source vault root always stays; only prune children.
            if relDir.isEmpty { return true }
            let prefix = relDir + "/"
            for path in localFiles where path == relDir || path.hasPrefix(prefix) {
                return true
            }
            return false
        }

        func removeStateKeys(underRel rel: String, isDirectory: Bool) {
            let base = BackupSyncState.key(vaultFolder: vaultFolderName, relativePath: rel)
            if isDirectory {
                let prefix = base + "/"
                let victims = syncState.files.keys.filter { $0 == base || $0.hasPrefix(prefix) }
                for key in victims {
                    syncState.files.removeValue(forKey: key)
                }
            } else {
                syncState.files.removeValue(forKey: base)
            }
        }

        func prune(dirId: String, relPrefix: String) async throws -> Int {
            try Task.checkCancellation()
            let children = try await session.list(dirId: dirId)
            var deleted = 0
            for child in children {
                try Task.checkCancellation()
                let childRel = relPrefix.isEmpty
                    ? child.cleartextName
                    : relPrefix + "/" + child.cleartextName
                await MainActor.run {
                    self.currentPath = childRel
                }
                switch child.kind {
                case .file, .symlink:
                    if !localFiles.contains(childRel) {
                        // Remote ObjectStore ciphertext delete only — never local source.
                        try await session.deleteFile(node: child)
                        removeStateKeys(underRel: childRel, isDirectory: false)
                        deleted += 1
                    }
                case .directory:
                    guard let childDirId = child.dirId else { continue }
                    if !hasLocalUnder(childRel) {
                        // Entire subtree is vault-only under this source folder.
                        try await session.deleteDirectory(node: child, recursive: true)
                        removeStateKeys(underRel: childRel, isDirectory: true)
                        deleted += 1
                    } else {
                        deleted += try await prune(dirId: childDirId, relPrefix: childRel)
                    }
                }
            }
            return deleted
        }

        return try await prune(dirId: rootDirId, relPrefix: "")
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

    nonisolated private func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            var rel = String(path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    enum SyncError: LocalizedError {
        case missingSource(String)
        case missingParent(String)
        case volumeLost(String)
        var errorDescription: String? {
            switch self {
            case .missingSource(let p):
                return "Source folder missing: \(p). Sync stopped fail-closed (not treated as an empty tree)."
            case .missingParent(let p):
                return "Parent folder not registered for \(p)"
            case .volumeLost(let p):
                return "Backup source volume disappeared during Sync: \(p). Sync stopped fail-closed (no wipe / no silent empty-tree success)."
            }
        }
    }

    /// Fail-closed: SMB / network volumes must stay mounted for the whole Sync.
    nonisolated private func assertSourceStillPresent(path: String, isSMB: Bool) throws {
        do {
            try SMBBackupMount.assertSourceReachable(path: path, isSMB: isSMB)
        } catch {
            throw SyncError.volumeLost(path)
        }
    }
}
