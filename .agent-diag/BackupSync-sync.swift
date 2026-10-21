
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
