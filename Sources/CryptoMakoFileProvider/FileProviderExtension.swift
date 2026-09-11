import CryptoMakoVault
import FileProvider
import Foundation

/// Read-only replicated File Provider over a Cryptomator format-8 vault on S3.
///
/// Decryption happens here, in-process. Finder never sees ciphertext, and no
/// FUSE layer is stacked on top of another provider.
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
            guard let parsed = ItemID.parse(identifier) else {
                throw NSFileProviderError(.noSuchItem)
            }
            switch parsed {
            case .root:
                completionHandler(VaultItem.root(displayName: domain.displayName), nil)
            case .directory(let dirId):
                guard let info = try await index.directoryInfo(dirId: dirId) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                completionHandler(
                    VaultItem.directory(
                        dirId: dirId,
                        parentDirId: info.parentDirId,
                        name: info.name
                    ),
                    nil
                )
            case .file(let parentDirId, let cipherName):
                guard let node = try await index.file(parentDirId: parentDirId, cipherName: cipherName) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                completionHandler(VaultItem.file(node: node), nil)
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
        run { [index] in
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
            completionHandler(destination, VaultItem.file(node: node), nil)
        } onError: { error in
            completionHandler(nil, nil, error)
        }
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        switch ItemID.parse(containerItemIdentifier) {
        case .root:
            return VaultEnumerator(dirId: "", index: index)
        case .directory(let dirId):
            return VaultEnumerator(dirId: dirId, index: index)
        default:
            throw NSFileProviderError(.noSuchItem)
        }
    }

    // MARK: - Writes (M3)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, Self.readOnly)
        return Progress(totalUnitCount: 1)
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
        completionHandler(nil, [], false, Self.readOnly)
        return Progress(totalUnitCount: 1)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(Self.readOnly)
        return Progress(totalUnitCount: 1)
    }

    // MARK: - Helpers

    private static var readOnly: Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }

    /// Returns a `Progress` the system can cancel; without one it may kill the
    /// request out from under us on slow links.
    private func run(
        _ body: @escaping () async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                try await body()
            } catch {
                onError(error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
