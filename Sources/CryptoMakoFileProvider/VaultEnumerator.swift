import CryptoMakoVault
import FileProvider
import Foundation

final class VaultEnumerator: NSObject, NSFileProviderEnumerator {
    private let dirId: String
    private let index: VaultIndex
    private var task: Task<Void, Never>?

    init(dirId: String, index: VaultIndex) {
        self.dirId = dirId
        self.index = index
    }

    func invalidate() {
        task?.cancel()
        task = nil
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                let nodes = try await index.children(of: dirId)
                var items: [NSFileProviderItem] = []
                for node in nodes {
                    switch node.kind {
                    case .directory:
                        guard let childId = node.dirId else { continue }
                        items.append(
                            VaultItem.directory(
                                dirId: childId,
                                parentDirId: dirId,
                                name: node.cleartextName
                            )
                        )
                    case .file:
                        items.append(VaultItem.file(node: node))
                    case .symlink:
                        // Listed but not followed; a symlink target is outside the PoC.
                        continue
                    }
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// The PoC refreshes on demand rather than polling S3, so there is never a
    /// change to report; the anchor stays put until the host app signals.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("v1".utf8)))
    }
}
