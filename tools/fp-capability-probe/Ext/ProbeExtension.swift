import FileProvider
import Foundation
import os
import UniformTypeIdentifiers

final class ProbeItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?

    init(_ id: NSFileProviderItemIdentifier, _ parent: NSFileProviderItemIdentifier, _ name: String, folder: Bool, phase: Int) {
        itemIdentifier = id
        parentItemIdentifier = parent
        filename = name
        contentType = folder ? .folder : .plainText
        var caps: NSFileProviderItemCapabilities = folder
            ? [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating, .allowsDeleting, .allowsRenaming, .allowsReparenting]
            : [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        if phase >= 2 { caps.insert(.allowsEvicting) }
        capabilities = caps
        itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((folder ? "dir" : "c1-\(name)").utf8),
            metadataVersion: Data("m\(phase)".utf8)
        )
        documentSize = folder ? nil : NSNumber(value: ProbeStore.content(name).count)
    }
}

enum ProbeStore {
    static func content(_ name: String) -> Data { Data("probe file \(name)\n".utf8) }

    static func all(phase: Int) -> [ProbeItem] {
        [
            ProbeItem(.rootContainer, .rootContainer, "CMProbe", folder: true, phase: phase),
            ProbeItem(NSFileProviderItemIdentifier("d1"), .rootContainer, "dir", folder: true, phase: phase),
            ProbeItem(NSFileProviderItemIdentifier("f1"), NSFileProviderItemIdentifier("d1"), "a.txt", folder: false, phase: phase),
            ProbeItem(NSFileProviderItemIdentifier("f2"), NSFileProviderItemIdentifier("d1"), "b.txt", folder: false, phase: phase),
        ]
    }

    static func item(_ id: NSFileProviderItemIdentifier, phase: Int) -> ProbeItem? {
        all(phase: phase).first { $0.itemIdentifier == id }
    }
}

final class ProbeExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let collector: MaterializedCollector

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        collector = MaterializedCollector(domain: domain)
        super.init()
        plog.notice("probe ext init phase=\(ProbeControl.phase, privacy: .public) mode=\(ProbeControl.mode, privacy: .public)")
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let phase = ProbeControl.phase
        plog.notice("item(for: \(identifier.rawValue, privacy: .public)) phase=\(phase, privacy: .public)")
        if identifier == .workingSet || identifier == .trashContainer {
            completionHandler(ProbeItem(identifier, .rootContainer, identifier.rawValue, folder: true, phase: phase), nil)
        } else if let i = ProbeStore.item(identifier, phase: phase) {
            completionHandler(i, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let phase = ProbeControl.phase
        guard let i = ProbeStore.item(itemIdentifier, phase: phase) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return Progress()
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? ProbeStore.content(i.filename).write(to: url)
        plog.notice("fetchContents \(itemIdentifier.rawValue, privacy: .public) phase=\(phase, privacy: .public)")
        completionHandler(url, i, nil)
        return Progress()
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        plog.notice("modifyItem \(item.itemIdentifier.rawValue, privacy: .public) fields=\(changedFields.rawValue, privacy: .public)")
        completionHandler(ProbeStore.item(item.itemIdentifier, phase: ProbeControl.phase), [], false, nil)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        plog.notice("enumerator(for: \(containerItemIdentifier.rawValue, privacy: .public))")
        if containerItemIdentifier == .workingSet { return WorkingSet(collector: collector) }
        if containerItemIdentifier == .trashContainer { return FolderEnum(parent: .trashContainer) }
        return FolderEnum(parent: containerItemIdentifier)
    }
}

final class FolderEnum: NSObject, NSFileProviderEnumerator {
    let parent: NSFileProviderItemIdentifier
    init(parent: NSFileProviderItemIdentifier) { self.parent = parent }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let kids = ProbeStore.all(phase: ProbeControl.phase).filter { $0.parentItemIdentifier == parent && $0.itemIdentifier != .rootContainer }
        observer.didEnumerate(kids)
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("folder".utf8)))
    }
}

/// Mirrors CryptoMako's approach: collect via enumeratorForMaterializedItems outside
/// enumerateChanges, then report didUpdate from the working set.
actor MaterializedCollector {
    let domain: NSFileProviderDomain
    var ids: [NSFileProviderItemIdentifier]?
    var collecting = false
    init(domain: NSFileProviderDomain) { self.domain = domain }

    func take() -> [NSFileProviderItemIdentifier]? { let v = ids; ids = nil; return v }

    func start() {
        guard !collecting else { return }
        collecting = true
        let domain = self.domain
        Task.detached {
            var found: [NSFileProviderItemIdentifier] = []
            do {
                guard let m = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
                let e = m.enumeratorForMaterializedItems()
                var page = NSFileProviderPage(Data())  // materialized set wants an empty page
                var pages = 0
                while true {
                    let (items, next) = try await Pager.page(e, page)
                    pages += 1
                    for it in items {
                        let caps = it.capabilities.map { String($0.rawValue) } ?? "nil"
                        let dl = it.isDownloaded.map { String($0) } ?? "nil"
                        let up = it.isUploaded.map { String($0) } ?? "nil"
                        let mv = it.itemVersion.map { String(decoding: $0.metadataVersion, as: UTF8.self) } ?? "nil"
                        plog.notice("materialized item id=\(it.itemIdentifier.rawValue, privacy: .public) parent=\(it.parentItemIdentifier.rawValue, privacy: .public) name=\(it.filename, privacy: .public) caps=\(caps, privacy: .public) downloaded=\(dl, privacy: .public) uploaded=\(up, privacy: .public) meta=\(mv, privacy: .public)")
                        found.append(it.itemIdentifier)
                    }
                    guard let next else { break }
                    page = next
                }
                e.invalidate()
                plog.notice("materialized enumeration: pages=\(pages, privacy: .public) items=\(found.count, privacy: .public)")
            } catch {
                plog.error("materialized enumeration failed: \(String(describing: error), privacy: .public)")
            }
            await self.done(found)
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }

    func done(_ f: [NSFileProviderItemIdentifier]) { ids = f; collecting = false }
}

final class Pager: NSObject, NSFileProviderEnumerationObserver {
    var items: [NSFileProviderItem] = []
    var cont: CheckedContinuation<([NSFileProviderItem], NSFileProviderPage?), Error>?
    static func page(_ e: NSFileProviderEnumerator, _ p: NSFileProviderPage) async throws -> ([NSFileProviderItem], NSFileProviderPage?) {
        let o = Pager()
        return try await withCheckedThrowingContinuation { c in o.cont = c; e.enumerateItems(for: o, startingAt: p) }
    }
    func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
    func finishEnumerating(upTo nextPage: NSFileProviderPage?) { cont?.resume(returning: (items, nextPage)); cont = nil }
    func finishEnumeratingWithError(_ error: Error) { cont?.resume(throwing: error); cont = nil }
}

final class WorkingSet: NSObject, NSFileProviderEnumerator {
    let collector: MaterializedCollector
    init(collector: MaterializedCollector) { self.collector = collector }
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        plog.notice("workingSet enumerateItems")
        observer.finishEnumerating(upTo: nil)
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let a = "a\(ProbeControl.phase)"
        plog.notice("workingSet currentSyncAnchor -> \(a, privacy: .public)")
        completionHandler(NSFileProviderSyncAnchor(Data(a.utf8)))
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let phase = ProbeControl.phase
        let from = String(decoding: anchor.rawValue, as: UTF8.self)
        let want = "a\(phase)"
        plog.notice("workingSet enumerateChanges from=\(from, privacy: .public) want=\(want, privacy: .public) mode=\(ProbeControl.mode, privacy: .public)")
        if from == want { observer.finishEnumeratingChanges(upTo: anchor, moreComing: false); return }
        if ProbeControl.mode == "all" {
            let items = ProbeStore.all(phase: phase)
            observer.didUpdate(items)
            plog.notice("workingSet reported \(items.count, privacy: .public) (all)")
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(want.utf8)), moreComing: false)
            return
        }
        Task {
            guard let ids = await collector.take() else {
                await collector.start()
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            let items = ids.compactMap { ProbeStore.item($0, phase: phase) }
            if !items.isEmpty { observer.didUpdate(items) }
            plog.notice("workingSet reported \(items.count, privacy: .public) of \(ids.count, privacy: .public) materialized")
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data(want.utf8)), moreComing: false)
        }
    }
}
