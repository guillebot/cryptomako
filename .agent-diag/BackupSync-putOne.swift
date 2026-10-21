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
        // Cache root path once — avoid per-file standardizedFileURL (SMB-expensive).
        let rootPath = localRoot.path
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
