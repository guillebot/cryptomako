import CryptoMakoVault
import FileProvider
import Foundation
import OSLog

final class VaultEnumerator: NSObject, NSFileProviderEnumerator {
    private let dirId: String
    /// Must be the **exact** `itemIdentifier` of this container so children's
    /// `parentItemIdentifier` matches (FPFS disconnects on mismatch — e.g. `d:id` vs `d:/id`).
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let index: VaultIndex
    private var task: Task<Void, Never>?

    init(
        dirId: String,
        containerIdentifier: NSFileProviderItemIdentifier,
        index: VaultIndex
    ) {
        self.dirId = dirId
        self.containerIdentifier = containerIdentifier
        self.index = index
    }

    func invalidate() {
        task?.cancel()
        task = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                // Refresh listing from S3, but keep DirectoryIndex parent map via children().
                await index.invalidateListing()
                let nodes = try await index.children(of: dirId)
                log.info("enumerate dirId=\(self.dirId, privacy: .public) count=\(nodes.count)")
                var items: [NSFileProviderItem] = []
                for node in nodes {
                    switch node.kind {
                    case .directory:
                        guard let childId = node.dirId else { continue }
                        items.append(
                            VaultItem.directory(
                                dirId: childId,
                                parentDirId: dirId,
                                name: node.cleartextName,
                                parentItemIdentifier: containerIdentifier
                            )
                        )
                    case .file:
                        items.append(
                            VaultItem.file(node: node, parentItemIdentifier: containerIdentifier)
                        )
                    case .symlink:
                        continue
                    }
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                log.error("enumerate failed dirId=\(self.dirId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Push a full refresh of children. A no-op finish left FPFS stuck on stale
        // directory capabilities (Delete hidden in Finder) after VaultItem updates.
        task = Task {
            do {
                await index.invalidateListing()
                let nodes = try await index.children(of: dirId)
                var updated: [NSFileProviderItem] = []
                for node in nodes {
                    switch node.kind {
                    case .directory:
                        guard let childId = node.dirId else { continue }
                        updated.append(
                            VaultItem.directory(
                                dirId: childId,
                                parentDirId: dirId,
                                name: node.cleartextName,
                                parentItemIdentifier: containerIdentifier
                            )
                        )
                    case .file:
                        updated.append(
                            VaultItem.file(node: node, parentItemIdentifier: containerIdentifier)
                        )
                    case .symlink:
                        continue
                    }
                }
                if !updated.isEmpty {
                    observer.didUpdate(updated)
                }
                observer.finishEnumeratingChanges(upTo: Self.makeAnchor(), moreComing: false)
            } catch {
                log.error(
                    "enumerateChanges failed dirId=\(self.dirId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.makeAnchor())
    }

    private static func makeAnchor() -> NSFileProviderSyncAnchor {
        let stamp = String(Date().timeIntervalSince1970)
        return NSFileProviderSyncAnchor(Data(stamp.utf8))
    }
}


/// workingSet / trashContainer must enumerate without throwing. We permanent-delete
/// on Delete (no soft trash inventory), so both containers stay empty.
final class EmptyVaultEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}
