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
            let rel = relativePath(fileURL, underRootPath: rootPath)
            if excludes.shouldSkipRelativePath(rel) { continue }

            localFiles.insert(rel)

            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? Date.distantPast
            let stateKey = BackupSyncState.key(vaultFolder: vaultFolderName, relativePath: rel)
            let fingerprint = BackupFileFingerprint(size: size, contentModification: mtime)

            walkUI.noteDiscovered(bytes: size)
            walkUI.notePath(rel)

            if box.get(stateKey)?.matches(size: size, contentModification: mtime) == true {
                skipped.files += 1
                skipped.bytes += size
                sinceSave += 1
                walkUI.noteSkipped(bytes: size)
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
                    walkUI.noteSkipped(bytes: size)
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
            walkUI.noteQueued()
        }

        largeCont.finish()
        mediumCont.finish()
        smallCont.finish()
        walkPublishTask.cancel()
        if let snap = walkUI.take() {
            await applyWalkSnapshot(snap)
        }
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
