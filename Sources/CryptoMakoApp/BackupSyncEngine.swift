import CryptoMakoShared
import CryptoMakoVault
import Foundation
import OSLog

/// Walks picked local folders and writes into the vault via `VaultSession`
/// (encrypt + remote put per file). Directories stay ordered; file puts run with
/// bounded parallelism (many small files, few large) to fill the network pipe.
/// Pre-scans totals so the UI can show a real percent.
@MainActor
final class BackupSyncEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case running
        case finished(files: Int, bytes: Int64)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentPath: String = ""
    @Published private(set) var currentSourceName: String = ""
    @Published private(set) var filesDone: Int = 0
    @Published private(set) var bytesDone: Int64 = 0
    @Published private(set) var filesTotal: Int = 0
    @Published private(set) var bytesTotal: Int64 = 0
    /// Live counters while `state == .scanning` (pre-upload local walk).
    @Published private(set) var filesFoundWhileScanning: Int = 0
    @Published private(set) var bytesFoundWhileScanning: Int64 = 0
    /// Files discovered and queued during folder prep (before parallel puts).
    @Published private(set) var filesQueued: Int = 0
    /// Files skipped because unchanged (local index) or already present in the vault.
    @Published private(set) var filesSkipped: Int = 0
    /// True while creating/resolving vault directories; false while putting files.
    @Published private(set) var isPreparingDirectories: Bool = false
    /// Job upload rate (cleartext bytes committed in the put phase only; skips excluded).
    @Published private(set) var uploadBytesPerSecond: Double = 0

    nonisolated private static let syncLog = Logger(subsystem: "net.gschimmel.cryptomako", category: "backup-sync")

    private var task: Task<Void, Never>?
    private var putRateWindowStartedAt: Date?
    private var putRateWindowBytes: Int64 = 0

    var isRunning: Bool {
        switch state {
        case .scanning, .running: return true
        default: return false
        }
    }

    /// 0…1 based on bytes when known, else files. 0 while scanning / idle.
    var progressFraction: Double {
        switch state {
        case .scanning:
            return 0
        case .running, .finished:
            // Folder prep: show queueing progress so the counter is not stuck at 0/N.
            if isPreparingDirectories, filesTotal > 0 {
                return min(1, Double(filesQueued) / Double(filesTotal))
            }
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
        case .scanning:
            return "Scanning…"
        case .running:
            if isPreparingDirectories {
                return filesTotal > 0 ? "\(pct)%" : "…"
            }
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

    /// Numerator for the Backup progress line (queued while preparing, uploaded while putting).
    var progressFilesDisplay: Int {
        if isPreparingDirectories { return filesQueued }
        return filesDone
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning {
            state = .failed("Cancelled")
        }
    }

    func sync(sources: [BackupSource], session: VaultSession) {
        cancel()
        state = .scanning
        filesDone = 0
        bytesDone = 0
        filesTotal = 0
        bytesTotal = 0
        filesFoundWhileScanning = 0
        bytesFoundWhileScanning = 0
        filesQueued = 0
        filesSkipped = 0
        isPreparingDirectories = false
        uploadBytesPerSecond = 0
        putRateWindowStartedAt = nil
        putRateWindowBytes = 0
        currentPath = "Counting local files…"
        currentSourceName = sources.first?.vaultFolderName ?? ""

        // Detached: do not inherit @MainActor for the long scan/upload pipeline
        // (MainActor inheritance serialized prep LIST/UI hops and starved PUT scheduling).
        task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let excludes = BackupSyncExcludesStore.load()
                let bandwidthLimiter = UploadBandwidthLimiter.fromPreferences(AppPreferences.load())
                let plan = try await self.scanWithProgress(sources: sources, excludes: excludes)
                try Task.checkCancellation()
                await MainActor.run {
                    self.filesTotal = plan.files
                    self.bytesTotal = plan.bytes
                    self.state = .running
                    self.currentPath = plan.files == 0 ? "No regular files to upload" : "Starting upload…"
                }

                _ = try await session.ensureDirectoryPath("Backups")
                var files = 0
                var bytes: Int64 = 0
                var syncState = BackupSyncState.load()
                for source in sources {
                    try Task.checkCancellation()
                    await MainActor.run { self.currentSourceName = source.vaultFolderName }
                    let root = URL(fileURLWithPath: source.path, isDirectory: true)
                    let isSMB = source.isSMB
                    guard FileManager.default.fileExists(atPath: root.path) else {
                        throw SyncError.missingSource(source.path)
                    }
                    try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
                    let vaultRoot = "Backups/\(source.vaultFolderName)"
                    let leafDirId = try await session.ensureDirectoryPath(vaultRoot)
                    let result = try await self.uploadTree(
                        localRoot: root,
                        parentDirId: leafDirId,
                        session: session,
                        vaultFolderName: source.vaultFolderName,
                        syncState: &syncState,
                        excludes: excludes,
                        bandwidthLimiter: bandwidthLimiter,
                        isSMB: isSMB
                    )
                    syncState.save()
                    files += result.files
                    bytes += result.bytes
                    await MainActor.run {
                        self.filesDone = files
                        self.bytesDone = bytes
                    }
                }
                syncState.save()
                await MainActor.run {
                    self.currentPath = ""
                    self.currentSourceName = ""
                    self.filesDone = files
                    self.bytesDone = bytes
                    self.state = .finished(files: files, bytes: bytes)
                }
            } catch is CancellationError {
                await MainActor.run { self.state = .failed("Cancelled") }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private struct Count {
        var files: Int
        var bytes: Int64
    }

    /// Count regular files (skip symlinks / packages / hidden / sync excludes) before uploading.
    /// Publishes live totals so the Backup UI is not blank during a long walk of ~/dev.
    nonisolated private func scanWithProgress(
        sources: [BackupSource],
        excludes: BackupSyncExcludes
    ) async throws -> Count {
        var total = Count(files: 0, bytes: 0)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        var sinceUI = 0
        for source in sources {
            try Task.checkCancellation()
            await MainActor.run {
                self.currentSourceName = source.vaultFolderName
                self.currentPath = source.path
            }
            let root = URL(fileURLWithPath: source.path, isDirectory: true)
            let isSMB = source.isSMB
            guard fm.fileExists(atPath: root.path) else {
                throw SyncError.missingSource(source.path)
            }
            try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                // Enumerator nil on a still-present root is unexpected; fail closed for network sources.
                if isSMB || SMBBackupMount.looksLikeNetworkVolume(root) {
                    throw SyncError.volumeLost(source.path)
                }
                continue
            }

            var sinceVolumeCheck = 0
            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                sinceVolumeCheck += 1
                if sinceVolumeCheck >= 200 {
                    sinceVolumeCheck = 0
                    try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
                }
                let values: URLResourceValues
                do {
                    values = try fileURL.resourceValues(forKeys: Set(keys))
                } catch {
                    try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
                    throw error
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if excludes.shouldSkipDirectory(named: fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                    // Occasionally show which subtree we are walking.
                    sinceUI += 1
                    if sinceUI % 40 == 0 {
                        let rel = self.relativePath(fileURL, under: root)
                        let files = total.files
                        let bytes = total.bytes
                        await MainActor.run {
                            self.currentPath = rel.isEmpty ? source.path : rel
                            self.filesFoundWhileScanning = files
                            self.bytesFoundWhileScanning = bytes
                        }
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let name = fileURL.lastPathComponent
                if excludes.shouldSkipFile(named: name) { continue }
                let rel = self.relativePath(fileURL, under: root)
                if excludes.shouldSkipRelativePath(rel) { continue }
                total.files += 1
                total.bytes += Int64(values.fileSize ?? 0)
                sinceUI += 1
                // Throttle UI updates — ~/dev can be huge.
                if sinceUI >= 25 {
                    sinceUI = 0
                    let files = total.files
                    let bytes = total.bytes
                    await MainActor.run {
                        self.filesFoundWhileScanning = files
                        self.bytesFoundWhileScanning = bytes
                        self.currentPath = rel
                    }
                }
            }
            try self.assertSourceStillPresent(path: root.path, isSMB: isSMB)
        }
        await MainActor.run {
            self.filesFoundWhileScanning = total.files
            self.bytesFoundWhileScanning = total.bytes
            self.currentPath = "Scan complete — \(total.files) files"
        }
        return total
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
    /// `currentPath` / `filesDone` after every object.
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
        isSMB: Bool
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
        var skipped = Count(files: 0, bytes: 0)
        var sinceSave = 0
        var queuedSinceUI = 0
        var skippedSinceUI = 0
        var skippedBytesSinceUI: Int64 = 0
        var lastUI = Date()
        let dirCache = DirIdCache(rootDirId: parentDirId, session: session)

        func cachedFileNames(_ dirId: String) async throws -> Set<String> {
            if let hit = fileNameCache[dirId] { return hit }
            let names = try await session.listFileNames(dirId: dirId)
            fileNameCache[dirId] = names
            return names
        }

        func flushUI(force: Bool, path: String?) async {
            let now = Date()
            guard force
                    || queuedSinceUI + skippedSinceUI >= 40
                    || now.timeIntervalSince(lastUI) >= 0.2
            else { return }
            let q = queuedSinceUI
            let s = skippedSinceUI
            let sb = skippedBytesSinceUI
            let p = path
            queuedSinceUI = 0
            skippedSinceUI = 0
            skippedBytesSinceUI = 0
            lastUI = now
            await MainActor.run {
                if q > 0 { self.filesQueued += q }
                if s > 0 {
                    self.filesSkipped += s
                    self.filesDone += s
                    self.bytesDone += sb
                }
                if let p { self.currentPath = p }
            }
        }

        await MainActor.run {
            self.isPreparingDirectories = true
            self.currentPath = "Indexing local files (skip unchanged / excludes)…"
        }

        // Three priority streams: large / medium / small. Walk yields without
        // awaiting MinIO so the buffers fill from local disk; workers resolve
        // vault dirs and PUT. Previous design did resolveDirId on the walk
        // thread → stream starved → inFlight collapsed to 1–2.
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
                self.filesDone += batch.files
                self.bytesDone += batch.bytes
                if let p = batch.path { self.currentPath = p }
                self.notePutCommitted(bytes: batch.bytes)
            }
        }

        func runWorker(stream: AsyncStream<PendingUpload>) async throws {
            for await job in stream {
                try Task.checkCancellation()
                // Pace Sync puts only (Finder File Provider uses a different path).
                if let limiter = bandwidthLimiter {
                    await limiter.acquire(job.size)
                }
                let parentId = try await dirCache.resolve(job.parentRel)
                _ = try await session.createOrOverwriteFile(
                    parentDirId: parentId,
                    cleartextName: job.fileURL.lastPathComponent,
                    contentsURL: job.fileURL
                )
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
                if let batch = uiBatcher.note(path: job.relativePath, bytes: job.size) {
                    await applyUIBatch(batch)
                }
            }
        }

        async let uploadResult: Count = {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<smallWorkers {
                    group.addTask { try await runWorker(stream: smallStream) }
                }
                for _ in 0..<mediumWorkers {
                    group.addTask { try await runWorker(stream: mediumStream) }
                }
                for _ in 0..<largeWorkers {
                    group.addTask { try await runWorker(stream: largeStream) }
                }
                await MainActor.run {
                    self.isPreparingDirectories = false
                    self.currentPath = "Uploading (up to \(workerCount) concurrent puts)…"
                }
                Self.syncLog.info(
                    "uploadPending worker pool start small=\(smallWorkers) medium=\(mediumWorkers) large=\(largeWorkers)"
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

        // Local-first walk: disk only. Unchanged → skip. New/changed → enqueue
        // without waiting for MinIO (dir resolve happens in put workers).
        var sinceVolumeCheck = 0
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

            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date.distantPast
            let stateKey = BackupSyncState.key(vaultFolder: vaultFolderName, relativePath: rel)
            let fingerprint = BackupFileFingerprint(size: size, contentModification: mtime)

            queuedSinceUI += 1

            if box.get(stateKey)?.matches(size: size, contentModification: mtime) == true {
                skipped.files += 1
                skipped.bytes += size
                sinceSave += 1
                skippedSinceUI += 1
                skippedBytesSinceUI += size
                await flushUI(force: false, path: rel)
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
                    await flushUI(force: false, path: rel)
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
            await flushUI(force: false, path: rel)
        }

        largeCont.finish()
        mediumCont.finish()
        smallCont.finish()
        await flushUI(force: true, path: nil)
        box.save()
        try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        await MainActor.run { self.isPreparingDirectories = false }

        let uploaded = try await uploadResult
        try assertSourceStillPresent(path: localRoot.path, isSMB: isSMB)
        syncState = box.snapshot()
        syncState.save()
        return Count(files: skipped.files + uploaded.files, bytes: skipped.bytes + uploaded.bytes)
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
