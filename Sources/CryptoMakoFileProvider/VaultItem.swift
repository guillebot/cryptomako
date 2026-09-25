import CryptoMakoVault
import FileProvider
import Foundation
import UniformTypeIdentifiers

enum ItemID {
    /// Own identity of a directory (includes parent so delete never needs a cache walk).
    static func directory(dirId: String, parentDirId: String) -> NSFileProviderItemIdentifier {
        if dirId.isEmpty { return .rootContainer }
        return NSFileProviderItemIdentifier(
            ItemIdentifier.directory(dirId: dirId, parentDirId: parentDirId).rawValue
        )
    }

    /// Canonical id for "the directory with this dirId" when parent is vault root
    /// (`d:/<dirId>`). Prefer passing the exact container `itemIdentifier` from the
    /// enumerator instead of reconstructing.
    static func directoryIdentifier(dirId: String) -> NSFileProviderItemIdentifier {
        if dirId.isEmpty { return .rootContainer }
        // Match ItemIdentifier.directory(dirId:, parentDirId: "") → "d:/<dirId>".
        return NSFileProviderItemIdentifier(ItemIdentifier.directory(dirId: dirId, parentDirId: "").rawValue)
    }

    /// Parent reference used from write paths that only know the parent dirId.
    static func directoryRef(_ dirId: String) -> NSFileProviderItemIdentifier {
        directoryIdentifier(dirId: dirId)
    }

    static func file(parentDirId: String, cipherName: String) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(ItemIdentifier.file(parentDirId: parentDirId, cipherName: cipherName).rawValue)
    }

    static func node(_ node: VaultNode) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(ItemIdentifier.of(node).rawValue)
    }

    static func parse(_ identifier: NSFileProviderItemIdentifier) -> ItemIdentifier? {
        if identifier == .rootContainer {
            return .root
        }
        return ItemIdentifier(rawValue: identifier.rawValue)
    }
}

final class VaultItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let itemVersion: NSFileProviderItemVersion
    /// false → Finder can show cloud / “not downloaded” decoration for remote files.
    private let downloadedFlag: Bool

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        capabilities: NSFileProviderItemCapabilities,
        documentSize: NSNumber?,
        itemVersion: NSFileProviderItemVersion,
        downloaded: Bool = true
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = documentSize
        self.itemVersion = itemVersion
        self.downloadedFlag = downloaded
    }

    var isDownloaded: Bool { downloadedFlag }

    /// Remote-authoritative vault: directories exist on MinIO once listed.
    /// FPFS previously left folders as isUploaded=0, which can suppress Delete.
    var isUploaded: Bool { true }

    static func root(displayName: String) -> VaultItem {
        VaultItem(
            identifier: .rootContainer,
            parent: .rootContainer,
            filename: displayName,
            contentType: .folder,
            // Root is not deletable (remoteDelete rejects .root); still allow writes/adds.
            capabilities: [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating],
            documentSize: nil,
            itemVersion: directoryVersion
        )
    }

    static func directory(
        dirId: String,
        parentDirId: String,
        name: String,
        parentItemIdentifier: NSFileProviderItemIdentifier? = nil
    ) -> VaultItem {
        let parent = parentItemIdentifier ?? ItemID.directoryIdentifier(dirId: parentDirId)
        return VaultItem(
            identifier: ItemID.directory(dirId: dirId, parentDirId: parentDirId),
            parent: parent,
            filename: name,
            contentType: .folder,
            // Same delete model as files: .allowsDeleting (no .allowsTrashing) so Finder
            // shows Delete → deleteItem → fail-closed remote recursive MinIO delete.
            // Include .allowsRenaming for Finder menu parity with files (rename still
            // fail-closed in modifyItem until implemented).
            capabilities: directoryCapabilities,
            documentSize: nil,
            itemVersion: directoryVersion,
            downloaded: true
        )
    }

    static func file(
        node: VaultNode,
        parentItemIdentifier: NSFileProviderItemIdentifier? = nil,
        documentSize: NSNumber? = nil,
        downloaded: Bool = false
    ) -> VaultItem {
        // ETag is the natural contentVersion: it changes exactly when bytes change.
        let content = Data((node.eTag ?? "0").utf8)
        let parent = parentItemIdentifier ?? ItemID.directoryIdentifier(dirId: node.parentDirId)
        return VaultItem(
            identifier: ItemID.node(node),
            parent: parent,
            filename: node.cleartextName,
            contentType: Self.contentType(for: node.cleartextName),
            // No .allowsTrashing: Finder Move-to-Trash used local .Trash and hit Error -36
            // (stale NFS / parentItemNotYetPropagated) before modifyItem ran. Cmd-Delete
            // / Delete go through deleteItem → remote MinIO delete (fail-closed).
            capabilities: [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting],
            // Default size is ciphertext `node.size`; callers that just hydrated
            // cleartext (fetchContents) should pass the destination fileSize.
            documentSize: documentSize ?? node.size.map { NSNumber(value: $0) },
            itemVersion: NSFileProviderItemVersion(
                contentVersion: content,
                metadataVersion: content
            ),
            // Enumerated/remote items stay dataless until fetchContents marks downloaded.
            downloaded: downloaded
        )
    }


    /// Synthetic trash root so `item(for: .trashContainer)` does not fail closed.
    static func trashContainerItem() -> VaultItem {
        VaultItem(
            identifier: .trashContainer,
            parent: .rootContainer,
            filename: ".Trash",
            contentType: .folder,
            capabilities: [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems],
            documentSize: nil,
            itemVersion: directoryVersion,
            downloaded: true
        )
    }

    /// Synthetic working-set root (enumerates empty — we do not mirror a local working set).
    static func workingSetItem() -> VaultItem {
        VaultItem(
            identifier: .workingSet,
            parent: .rootContainer,
            filename: "Working Set",
            contentType: .folder,
            capabilities: [.allowsReading, .allowsContentEnumerating],
            documentSize: nil,
            itemVersion: directoryVersion,
            downloaded: true
        )
    }

    private static func contentType(for filename: String) -> UTType {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return .data
        }
        return type
    }

    /// Directory metadata version. Bump when capabilities/UI flags change so FPFS
    /// drops stale cached folder items (empty versionIdentifier otherwise sticks to
    /// pre-delete capabilities — Finder then hides Delete for directories only).
    private static let directoryVersion = NSFileProviderItemVersion(
        contentVersion: Data("dir-v2".utf8),
        metadataVersion: Data("caps-delete-v2".utf8)
    )

    /// Finder Delete for folders requires .allowsDeleting on the directory item.
    /// Mirrored from files except folder-specific add/enumerate aliases.
    private static let directoryCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading,
        .allowsWriting,
        .allowsAddingSubItems,
        .allowsContentEnumerating,
        .allowsDeleting,
        .allowsRenaming,
        .allowsReparenting,
    ]
}
