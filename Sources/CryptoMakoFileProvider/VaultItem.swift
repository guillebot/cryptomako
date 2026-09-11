import CryptoMakoVault
import FileProvider
import Foundation
import UniformTypeIdentifiers

enum ItemID {
    static func directory(_ dirId: String) -> NSFileProviderItemIdentifier {
        dirId.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(ItemIdentifier.directory(dirId: dirId).rawValue)
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

    init(
        identifier: NSFileProviderItemIdentifier,
        parent: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        capabilities: NSFileProviderItemCapabilities,
        documentSize: NSNumber?,
        itemVersion: NSFileProviderItemVersion
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = documentSize
        self.itemVersion = itemVersion
    }

    static func root(displayName: String) -> VaultItem {
        VaultItem(
            identifier: .rootContainer,
            parent: .rootContainer,
            filename: displayName,
            contentType: .folder,
            capabilities: [.allowsReading, .allowsContentEnumerating],
            documentSize: nil,
            itemVersion: constantVersion
        )
    }

    static func directory(
        dirId: String,
        parentDirId: String,
        name: String
    ) -> VaultItem {
        VaultItem(
            identifier: ItemID.directory(dirId),
            parent: ItemID.directory(parentDirId),
            filename: name,
            contentType: .folder,
            capabilities: [.allowsReading, .allowsContentEnumerating],
            documentSize: nil,
            itemVersion: constantVersion
        )
    }

    static func file(node: VaultNode) -> VaultItem {
        // ETag is the natural contentVersion: it changes exactly when bytes change.
        let content = Data((node.eTag ?? "0").utf8)
        return VaultItem(
            identifier: ItemID.node(node),
            parent: ItemID.directory(node.parentDirId),
            filename: node.cleartextName,
            contentType: Self.contentType(for: node.cleartextName),
            capabilities: [.allowsReading],
            documentSize: node.size.map { NSNumber(value: $0) },
            itemVersion: NSFileProviderItemVersion(
                contentVersion: content,
                metadataVersion: content
            )
        )
    }

    private static func contentType(for filename: String) -> UTType {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return .data
        }
        return type
    }

    /// Directory listings are re-read on demand, so a fixed version is honest here.
    private static let constantVersion = NSFileProviderItemVersion(
        contentVersion: Data("v1".utf8),
        metadataVersion: Data("v1".utf8)
    )
}
