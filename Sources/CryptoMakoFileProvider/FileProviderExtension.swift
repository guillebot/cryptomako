import CryptoMakoVault
import CryptoMakoShared
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Replicated File Provider over a Cryptomator format-8 vault on **remote** S3.
///
/// Decryption happens here, in-process. Finder never sees ciphertext.
///
/// **Remote-only writes:** `createItem` / `modifyItem` / `deleteItem` report success
/// only after `ObjectStore.putObject` / `deleteObject` succeeds on MinIO/S3.
/// Returning success without a remote put previously allowed rclone to fill
/// `~/Library/CloudStorage/CryptoMako-CryptoMako` with ~74GB of local-only
/// `backupsfotosfamilia` while the S3 vault still had only fixtures — that must
/// never happen again.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let index = VaultIndex()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        Task { await index.invalidate() }
    }

    // MARK: - Reads

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        run { [domain, index] in
            // System containers are not vault nodes; returning noSuchItem here
            // breaks trash / working-set bookkeeping and contributes to Finder -36.
            if identifier == .trashContainer {
                completionHandler(VaultItem.trashContainerItem(), nil)
                return
            }
            if identifier == .workingSet {
                completionHandler(VaultItem.workingSetItem(), nil)
                return
            }
            guard let parsed = ItemID.parse(identifier) else {
                throw NSFileProviderError(.noSuchItem)
            }
            switch parsed {
            case .root:
                completionHandler(VaultItem.root(displayName: domain.displayName), nil)
            case .directory(let dirId, let knownParent):
                let info = try await index.directoryInfo(dirId: dirId, hintParent: knownParent)
                guard let info else {
                    throw NSFileProviderError(.noSuchItem)
                }
                // Use full d:<grandparent>/<parent> when known — `d:/<parent>` alone
                // desyncs FPFS and yields parentItemNotYetPropagated / Finder -36.
                let parentItem = try await Self.fullDirectoryIdentifier(
                    dirId: info.parentDirId,
                    index: index
                )
                completionHandler(
                    VaultItem.directory(
                        dirId: dirId,
                        parentDirId: info.parentDirId,
                        name: info.name,
                        parentItemIdentifier: parentItem
                    ),
                    nil
                )
            case .file(let parentDirId, let cipherName):
                guard let node = try await index.file(parentDirId: parentDirId, cipherName: cipherName) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let parentItem = try await Self.fullDirectoryIdentifier(
                    dirId: parentDirId,
                    index: index
                )
                completionHandler(VaultItem.file(node: node, parentItemIdentifier: parentItem), nil)
            }
        } onError: { error in
            completionHandler(nil, error)
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        // Download-shaped Progress (not runUpload) so Finder shows downloading/receiving.
        return runDownload(byteCount: 1, fileName: nil, body: { [index] _ in
            guard case .file(let parentDirId, let cipherName)? = ItemID.parse(itemIdentifier) else {
                throw NSFileProviderError(.noSuchItem)
            }
            guard let node = try await index.file(parentDirId: parentDirId, cipherName: cipherName) else {
                throw NSFileProviderError(.noSuchItem)
            }
            let session = try await index.session()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("cryptomako-\(UUID().uuidString)")
            try await session.fetch(node: node, to: destination)
            // Cleartext size on disk — not ciphertext `node.size`.
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? (node.size ?? 0)
            TransferMetrics.recordDownload(bytes: size)
            // Mirror item(for:): full d:<grandparent>/<parent> — short d:/<parent>
            // desyncs FPFS (parentItemNotYetPropagated → materializationFailed).
            let parentItem = try await Self.fullDirectoryIdentifier(
                dirId: parentDirId,
                index: index
            )
            completionHandler(
                destination,
                VaultItem.file(
                    node: node,
                    parentItemIdentifier: parentItem,
                    documentSize: NSNumber(value: size),
                    downloaded: true
                ),
                nil
            )
        }, onError: { error in
            completionHandler(nil, nil, error)
        })
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        // Required system containers — must not throw (Finder Trash / FPFS sync).
        if containerItemIdentifier == .trashContainer || containerItemIdentifier == .workingSet {
            return EmptyVaultEnumerator()
        }
        switch ItemID.parse(containerItemIdentifier) {
        case .root:
            return VaultEnumerator(
                dirId: "",
                containerIdentifier: .rootContainer,
                index: index
            )
        case .directory(let dirId, _):
            return VaultEnumerator(
                dirId: dirId,
                containerIdentifier: containerItemIdentifier,
                index: index
            )
        default:
            throw NSFileProviderError(.noSuchItem)
        }
    }

    // MARK: - Writes (remote commit required)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let hintedSize: Int64 = {
            if let url,
               let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return Int64(n)
            }
            return 1
        }()
        return runUpload(byteCount: max(hintedSize, 1), fileName: itemTemplate.filename, body: { [index] progress in
            let session = try await index.session()
            let parentDirId = try Self.parentDirId(from: itemTemplate.parentItemIdentifier)
            let name = itemTemplate.filename

            if itemTemplate.contentType?.conforms(to: .folder) == true {
                let node = try await session.createDirectory(parentDirId: parentDirId, cleartextName: name)
                await index.invalidateListing()
                completionHandler(
                    VaultItem.directory(
                        dirId: node.dirId ?? "",
                        parentDirId: parentDirId,
                        name: name,
                        parentItemIdentifier: itemTemplate.parentItemIdentifier
                    ),
                    [],
                    false,
                    nil
                )
                return
            }

            guard let url else {
                // Empty file create: write zero bytes remotely.
                let empty = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cryptomako-empty-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: empty.path, contents: Data(), attributes: nil)
                defer { try? FileManager.default.removeItem(at: empty) }
                let node = try await session.createOrOverwriteFile(
                    parentDirId: parentDirId,
                    cleartextName: name,
                    contentsURL: empty
                )
                await index.invalidateListing()
                completionHandler(VaultItem.file(node: node, parentItemIdentifier: itemTemplate.parentItemIdentifier), [], false, nil)
                return
            }

            let node = try await session.createOrOverwriteFile(
                parentDirId: parentDirId,
                cleartextName: name,
                contentsURL: url
            )
            await index.invalidateListing()
            completionHandler(VaultItem.file(node: node, parentItemIdentifier: itemTemplate.parentItemIdentifier), [], false, nil)
            progress.completedUnitCount = progress.totalUnitCount
        }, onError: { error in
            // Fail closed: never report a local-only success.
            log.error("createItem failed (no remote commit): \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        })
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        log.info(
            "modifyItem name=\(item.filename, privacy: .public) fields=\(String(describing: changedFields), privacy: .public) parent=\(item.parentItemIdentifier.rawValue, privacy: .public)"
        )
        // Defensive: even without .allowsTrashing, some paths still reparent to trash.
        // Treat as permanent remote delete (product: fail-closed MinIO delete, no soft trash).
        // Huge folders need runLongDelete heartbeat or Finder aborts with -36.
        if changedFields.contains(.parentItemIdentifier), Self.isTrashIdentifier(item.parentItemIdentifier) {
            log.info("trash via modifyItem name=\(item.filename, privacy: .public) id=\(item.itemIdentifier.rawValue, privacy: .public)")
            return runLongDelete(label: "Deleting \(item.filename) from CryptoMako vault") { [index] progress in
                let session = try await index.session()
                guard let parsed = ItemID.parse(item.itemIdentifier) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                try await Self.remoteDelete(
                    parsed: parsed,
                    session: session,
                    index: index,
                    onProgress: { progress.pulse() }
                )
                await index.invalidateListing()
                completionHandler(nil, [], false, nil)
            } onError: { error in
                log.error("trash delete failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, error)
            }
        }

        let hintedSize: Int64 = {
            if let newContents,
               let n = try? newContents.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return Int64(n)
            }
            return 1
        }()
        return runUpload(byteCount: max(hintedSize, 1), fileName: item.filename, body: { [index] progress in
            let session = try await index.session()
            guard let parsed = ItemID.parse(item.itemIdentifier) else {
                throw NSFileProviderError(.noSuchItem)
            }

            if changedFields.contains(.contents), let newContents {
                guard case .file(let parentDirId, _) = parsed else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let node = try await session.createOrOverwriteFile(
                    parentDirId: parentDirId,
                    cleartextName: item.filename,
                    contentsURL: newContents
                )
                await index.invalidateListing()
                completionHandler(VaultItem.file(node: node), [], false, nil)
                return
            }

            // Rename / move not implemented — fail closed (never pretend success).
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                log.error(
                    "modifyItem unsupported fields: \(String(describing: changedFields), privacy: .public) parent=\(item.parentItemIdentifier.rawValue, privacy: .public) name=\(item.filename, privacy: .public)"
                )
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFeatureUnsupportedError,
                    userInfo: [NSLocalizedDescriptionKey: "Rename/move not supported yet"]
                )
            }

            completionHandler(item, [], false, nil)
            progress.completedUnitCount = progress.totalUnitCount
        }, onError: { error in
            log.error("modifyItem failed (no remote commit): \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        })
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // Large vault folders (photo libraries) need a live Progress heartbeat or
        // Finder kills the provider with Error -36 before remote deletes finish.
        log.info("deleteItem id=\(identifier.rawValue, privacy: .public)")
        return runLongDelete(label: "Deleting from CryptoMako vault") { [index] progress in
            let session = try await index.session()
            guard let parsed = ItemID.parse(identifier) else {
                throw NSFileProviderError(.noSuchItem)
            }
            try await Self.remoteDelete(
                parsed: parsed,
                session: session,
                index: index,
                onProgress: { progress.pulse() }
            )
            await index.invalidateListing()
            completionHandler(nil)
        } onError: { error in
            log.error("deleteItem failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    // MARK: - Helpers


    private static func isTrashIdentifier(_ id: NSFileProviderItemIdentifier) -> Bool {
        if id == .trashContainer { return true }
        let raw = id.rawValue.lowercased()
        // Defensive: some macOS builds surface trash with alternate raw values.
        return raw == "trash" || raw.hasSuffix("/trash") || raw.contains("trashcontainer")
    }

    private static func remoteDelete(
        parsed: ItemIdentifier,
        session: VaultSession,
        index: VaultIndex,
        onProgress: (@Sendable () -> Void)? = nil
    ) async throws {
        switch parsed {
        case .root:
            throw NSFileProviderError(.noSuchItem)
        case .directory(let dirId, let knownParent):
            let real = try await resolveDirectory(
                dirId: dirId,
                knownParent: knownParent,
                session: session,
                index: index
            )
            try await session.deleteDirectory(node: real, recursive: true, onProgress: onProgress)
        case .file(let parentDirId, let cipherName):
            guard let node = try await index.file(parentDirId: parentDirId, cipherName: cipherName) else {
                throw NSFileProviderError(.noSuchItem)
            }
            try await session.deleteFile(node: node)
            onProgress?()
        }
    }

    /// Resolve a directory's canonical item id including its parent (`d:parent/dir`).
    private static func fullDirectoryIdentifier(
        dirId: String,
        index: VaultIndex
    ) async throws -> NSFileProviderItemIdentifier {
        if dirId.isEmpty { return .rootContainer }
        if let info = try await index.directoryInfo(dirId: dirId, hintParent: nil) {
            return ItemID.directory(dirId: dirId, parentDirId: info.parentDirId)
        }
        return ItemID.directoryIdentifier(dirId: dirId)
    }

    private static func parentDirId(from parent: NSFileProviderItemIdentifier) throws -> String {
        switch ItemID.parse(parent) {
        case .root:
            return ""
        case .directory(let dirId, _):
            return dirId
        default:
            throw NSFileProviderError(.noSuchItem)
        }
    }

    /// Prefer parent embedded in the item id; fall back to DirectoryIndex walk.
    private static func resolveDirectory(
        dirId: String,
        knownParent: String?,
        session: VaultSession,
        index: VaultIndex
    ) async throws -> VaultNode {
        if let knownParent {
            let siblings = try await session.list(dirId: knownParent)
            if let real = siblings.first(where: { $0.dirId == dirId }) {
                return real
            }
            log.error("resolveDirectory miss id=\(dirId, privacy: .public) parent=\(knownParent, privacy: .public)")
        }
        guard let info = try await index.directoryInfo(dirId: dirId, hintParent: knownParent) else {
            throw NSFileProviderError(.noSuchItem)
        }
        let siblings = try await session.list(dirId: info.parentDirId)
        guard let real = siblings.first(where: { $0.dirId == dirId }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return real
    }

    /// Returns a `Progress` the system can cancel; without one it may kill the
    /// request out from under us on slow links.
    private func run(
        _ body: @escaping () async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        runUpload(byteCount: 1, fileName: nil, body: { _ in try await body() }, onError: onError)
    }

    /// Upload-shaped Progress so Finder copy sheets track *remote* work.
    /// Note: POSIX writers (rclone) still see local CloudStorage accept speed;
    /// this Progress is what fileproviderd/Finder use for the provider request.
    /// Long recursive deletes need a live Progress or Finder aborts with Error -36.
    private func runLongDelete(
        label: String,
        body: @escaping (Progress) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1_000_000)
        progress.kind = .file
        progress.setUserInfoObject(
            Progress.FileOperationKind.receiving,
            forKey: .fileOperationKindKey
        )
        progress.localizedDescription = label
        let task = Task {
            // Keep fileproviderd alive while MinIO deletes crawl a large tree.
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    progress.pulse()
                }
            }
            defer { heartbeat.cancel() }
            do {
                try await body(progress)
                progress.completedUnitCount = progress.totalUnitCount
            } catch {
                onError(error)
                progress.completedUnitCount = progress.totalUnitCount
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    /// Download-shaped Progress for fetchContents (Finder "downloading" UI).
    private func runDownload(
        byteCount: Int64,
        fileName: String?,
        body: @escaping (Progress) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        let total = max(byteCount, 1)
        let progress = Progress(totalUnitCount: total)
        progress.kind = .file
        progress.setUserInfoObject(
            Progress.FileOperationKind.downloading,
            forKey: .fileOperationKindKey
        )
        if let fileName {
            progress.localizedDescription = "Downloading \(fileName) from CryptoMako vault"
        }
        let task = Task {
            do {
                try await body(progress)
                progress.completedUnitCount = total
            } catch {
                onError(error)
                progress.completedUnitCount = total
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private func runUpload(
        byteCount: Int64,
        fileName: String?,
        body: @escaping (Progress) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        let total = max(byteCount, 1)
        let progress = Progress(totalUnitCount: total)
        progress.kind = .file
        progress.setUserInfoObject(
            Progress.FileOperationKind.uploading,
            forKey: .fileOperationKindKey
        )
        if let fileName {
            progress.localizedDescription = "Uploading \(fileName) to CryptoMako vault"
        }
        let task = Task {
            do {
                try await body(progress)
                progress.completedUnitCount = total
            } catch {
                onError(error)
                progress.completedUnitCount = total
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

private extension Progress {
    /// Advance without racing past totalUnitCount so Finder keeps the operation alive.
    func pulse() {
        let next = completedUnitCount + 1
        if next >= totalUnitCount {
            totalUnitCount += 1_000_000
        }
        completedUnitCount = next
    }
}
