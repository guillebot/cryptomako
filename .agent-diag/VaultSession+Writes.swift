import CryptomatorCryptoLib
import Foundation
import CryptoMakoS3
import CryptoMakoShared

extension VaultSession {
    /// Creates a directory in the vault. Durable only after remote `putObject` of `dir.c9r` + `dirid.c9r`.
    public func createDirectory(
        parentDirId: String,
        cleartextName: String,
        skipExistsCheck: Bool = false
    ) async throws -> VaultNode {
        let name = cleartextName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw VaultError.invalidPath(cleartextName)
        }
        if !skipExistsCheck,
           try await list(dirId: parentDirId).contains(where: { $0.cleartextName == name }) {
            throw VaultError.alreadyExists(name)
        }

        let childDirId = UUID().uuidString
        let prepared: (encName: String, folderKeyPrefix: String, dirMarkerKey: String, dirIdKey: String, displayCipherName: String, shortened: Bool)
        prepared = try withCryptor {
            let encName = try cryptor.encryptFileName(name, dirId: Data(parentDirId.utf8)) + ".c9r"
            let parentPrefix = try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: parentDirId
            )
            let shortened = encName.count > config.shorteningThreshold
            let displayCipherName = shortened
                ? DirLayout.shortenedName(ciphertextFileName: encName)
                : encName
            let folderKeyPrefix = parentPrefix + displayCipherName + "/"
            let dirMarkerKey = folderKeyPrefix + "dir.c9r"
            let childPrefix = try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: childDirId
            )
            let dirIdKey = childPrefix + "dirid.c9r"
            return (encName, folderKeyPrefix, dirMarkerKey, dirIdKey, displayCipherName, shortened)
        }

        let idData = Data(childDirId.utf8)
        TransferMetrics.beginPut(name: name + "/")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                if prepared.shortened {
                    let nameKey = prepared.folderKeyPrefix + "name.c9s"
                    let nameData = Data(prepared.encName.utf8)
                    group.addTask { try await self.store.putObject(key: nameKey, data: nameData) }
                }
                let markerKey = prepared.dirMarkerKey
                let idKey = prepared.dirIdKey
                let payload = idData
                group.addTask { try await self.store.putObject(key: markerKey, data: payload) }
                group.addTask { try await self.store.putObject(key: idKey, data: payload) }
                try await group.waitForAll()
            }
            TransferMetrics.endPutSuccess(bytes: Int64(idData.count * 2))
        } catch {
            TransferMetrics.endPutFailure(error.localizedDescription)
            throw error
        }

        return VaultNode(
            cleartextName: name,
            kind: .directory,
            cipherName: prepared.displayCipherName,
            parentDirId: parentDirId,
            dirId: childDirId,
            ciphertextKey: prepared.dirMarkerKey,
            size: nil,
            eTag: nil
        )
    }

    /// Encrypts cleartext and PUTs ciphertext remotely. Success requires remote put.
    /// Name cryptor work is brief+locked; content encrypt is parallel (GCD); PUTs concurrent.
    public func createOrOverwriteFile(
        parentDirId: String,
        cleartextName: String,
        contentsURL: URL
    ) async throws -> VaultNode {
        let name = cleartextName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw VaultError.invalidPath(cleartextName)
        }

        let clearURL = contentsURL
        let cipherURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cryptomako-enc-\(UUID().uuidString).c9r")
        defer { try? FileManager.default.removeItem(at: cipherURL) }

        // inFlight before encrypt: Sync can encrypt for seconds with zero PUT
        // bytes; beginPut-after-encrypt made TransferMetrics look frozen/stale.
        TransferMetrics.beginPut(name: name)
        do {
            // Fast name/dir-id work on the shared cryptor; content encrypt on a private
            // worker so Backup Sync can encrypt many files in parallel (was the main
            // CPU serial bottleneck keeping the uplink under ~1 Mbps).
            let prepared: (encName: String, parentPrefix: String) = try withCryptor {
                let encName = try cryptor.encryptFileName(name, dirId: Data(parentDirId.utf8)) + ".c9r"
                let parentPrefix = try DirLayout.ciphertextDirectoryPrefix(
                    prefix: location.prefix,
                    cryptor: cryptor,
                    dirId: parentDirId
                )
                return (encName, parentPrefix)
            }
            // Blocking AES on a GCD queue — never on the Swift cooperative pool.
            try await encryptContentOffPool(from: clearURL, to: cipherURL)

            let ciphertextKey: String
            let displayCipherName: String
            let cipherSize = (try? cipherURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if prepared.encName.count > config.shorteningThreshold {
                let short = DirLayout.shortenedName(ciphertextFileName: prepared.encName)
                let folder = prepared.parentPrefix + short + "/"
                ciphertextKey = folder + "contents.c9r"
                displayCipherName = short
                let nameKey = folder + "name.c9s"
                let nameData = Data(prepared.encName.utf8)
                let contentKey = ciphertextKey
                let contentURL = cipherURL
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.store.putObject(key: nameKey, data: nameData) }
                    group.addTask { try await self.store.putObject(key: contentKey, from: contentURL) }
                    try await group.waitForAll()
                }
            } else {
                ciphertextKey = prepared.parentPrefix + prepared.encName
                try await store.putObject(key: ciphertextKey, from: cipherURL)
                displayCipherName = prepared.encName
            }
            TransferMetrics.endPutSuccess(bytes: cipherSize)
            // Local ciphertext size is authoritative; skip remote HEAD (extra RTT).
            return VaultNode(
                cleartextName: name,
                kind: .file,
                cipherName: displayCipherName,
                parentDirId: parentDirId,
                dirId: nil,
                ciphertextKey: ciphertextKey,
                size: cipherSize,
                eTag: nil
            )
        } catch {
            TransferMetrics.endPutFailure(error.localizedDescription)
            throw error
        }
    }

    public func deleteFile(node: VaultNode) async throws {
        guard node.kind == .file else {
            throw VaultError.notAFile(node.cleartextName)
        }
        if node.cipherName.hasSuffix(".c9s") {
            let folder = node.ciphertextKey.replacingOccurrences(of: "contents.c9r", with: "")
            try? await store.deleteObject(key: folder + "name.c9s")
            try await store.deleteObject(key: node.ciphertextKey)
        } else {
            try await store.deleteObject(key: node.ciphertextKey)
        }
        TransferMetrics.recordDeleteSuccess()
    }

    /// Deletes a directory marker. Refuses if the directory still has children
    /// unless `recursive` is true (Finder folder delete / trash).
    /// Sibling files delete in parallel (bounded); nested directories recurse.
    /// `onProgress` fires after each remote object removal (for Finder Progress heartbeats).
    public func deleteDirectory(
        node: VaultNode,
        recursive: Bool = false,
        onProgress: (@Sendable () -> Void)? = nil
    ) async throws {
        guard node.kind == .directory, let dirId = node.dirId else {
            throw VaultError.notADirectory(node.cleartextName)
        }
        let children = try await list(dirId: dirId)
        if !children.isEmpty {
            guard recursive else {
                throw VaultError.directoryNotEmpty(node.cleartextName)
            }
            let files = children.filter { $0.kind == .file || $0.kind == .symlink }
            let dirs = children.filter { $0.kind == .directory }
            // Bound concurrency so we do not open hundreds of HTTPS deletes at once.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var inFlight = 0
                var next = 0
                let limit = 8
                func scheduleFiles() {
                    while next < files.count, inFlight < limit {
                        let child = files[next]
                        next += 1
                        inFlight += 1
                        group.addTask {
                            try await self.deleteFile(node: child)
                            onProgress?()
                        }
                    }
                }
                scheduleFiles()
                while inFlight > 0 {
                    try await group.next()
                    inFlight -= 1
                    scheduleFiles()
                }
            }
            for dir in dirs {
                try await deleteDirectory(node: dir, recursive: true, onProgress: onProgress)
            }
        }
        // Parent marker + child dirid must both leave the remote store.
        if !node.ciphertextKey.isEmpty {
            try await store.deleteObject(key: node.ciphertextKey)
            if node.cipherName.hasSuffix(".c9s") {
                let folder = node.ciphertextKey.replacingOccurrences(of: "dir.c9r", with: "")
                try? await store.deleteObject(key: folder + "name.c9s")
            }
            onProgress?()
        }
        let childPrefix = try withCryptor {
            try DirLayout.ciphertextDirectoryPrefix(
                prefix: location.prefix,
                cryptor: cryptor,
                dirId: dirId
            )
        }
        try? await store.deleteObject(key: childPrefix + "dirid.c9r")
        TransferMetrics.recordDeleteSuccess()
        onProgress?()
    }

    /// Delete any vault node; directories are removed recursively (remote ciphertext only).
    public func deleteNode(
        _ node: VaultNode,
        recursive: Bool = true,
        onProgress: (@Sendable () -> Void)? = nil
    ) async throws {
        switch node.kind {
        case .directory:
            try await deleteDirectory(node: node, recursive: recursive, onProgress: onProgress)
        case .file, .symlink:
            try await deleteFile(node: node)
            onProgress?()
        }
    }

}


extension VaultSession {
    /// Ensures `/a/b/c` exists as directories; returns the dirId of the leaf.
    public func ensureDirectoryPath(_ cleartextPath: String) async throws -> String {
        let parts = cleartextPath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        var parentDirId = ""
        for part in parts {
            let kids = try await list(dirId: parentDirId)
            if let existing = kids.first(where: { $0.kind == .directory && $0.cleartextName == part }),
               let id = existing.dirId
            {
                parentDirId = id
                continue
            }
            let created = try await createDirectory(parentDirId: parentDirId, cleartextName: part)
            guard let id = created.dirId else {
                throw VaultError.notADirectory(part)
            }
            parentDirId = id
        }
        return parentDirId
    }
}
