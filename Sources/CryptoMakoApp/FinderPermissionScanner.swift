import CryptoMakoShared
import Darwin
import FileProvider
import Foundation
import OSLog

private let scanLog = Logger(subsystem: "net.gschimmel.cryptomako", category: "finder-permissions")

/// App-side source for the capability refresh: lists downloaded (non-dataless)
/// files and listed folders under the CryptoMako Finder location and resolves
/// their File Provider identifiers. Read-only: the walk runs with dataless
/// materialization disabled (no downloads, no remote listings) and identifier
/// lookups only query fileproviderd's database. Nothing is evicted or modified.
enum FinderPermissionScanner {
    struct Found: Sendable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
    }

    /// Walks, resolves, writes `AppMaterializedList`, records the count in
    /// `CapabilityRefreshState`, then signals the working set.
    static func run(domain: NSFileProviderDomain) async -> String {
        guard let manager = NSFileProviderManager(for: domain) else { return "CryptoMako is not mounted in Finder" }
        let root: URL
        do {
            root = try await manager.getUserVisibleURL(for: .rootContainer).standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            return "could not find the Finder location: \(error.localizedDescription)"
        }
        let started = Date()
        scanLog.notice("finder permissions: scanning \(root.path, privacy: .public)")
        let found = await walk(root)
        var dirIds: [String: String] = [root.path: NSFileProviderItemIdentifier.rootContainer.rawValue]
        var entries: [AppMaterializedList.Entry] = []
        var unresolved = 0
        // Folders first (sorted by depth) so every parent is resolved before its children.
        let ordered = found.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.pathComponents.count < b.url.pathComponents.count
        }
        for f in ordered {
            guard let id = await identifier(for: f.url, domainID: domain.identifier) else {
                unresolved += 1
                continue
            }
            if f.isDirectory { dirIds[f.url.path] = id }
            guard let parent = dirIds[f.url.deletingLastPathComponent().path] else {
                unresolved += 1
                continue
            }
            entries.append(.init(
                identifier: id,
                parent: parent,
                filename: f.url.lastPathComponent,
                isDirectory: f.isDirectory,
                size: f.size
            ))
        }
        AppMaterializedList(createdAt: Date(), entries: entries).save()
        let files = entries.filter { !$0.isDirectory }.count
        CapabilityRefreshState.update { $0.appMaterializedCount = entries.count }
        let secs = Int(Date().timeIntervalSince(started))
        scanLog.notice("finder permissions: \(files, privacy: .public) downloaded file(s), \(entries.count - files, privacy: .public) folder(s), unresolved \(unresolved, privacy: .public), \(secs, privacy: .public)s; signalling working set")
        do {
            try await manager.signalEnumerator(for: .workingSet)
        } catch {
            scanLog.error("finder permissions: signalEnumerator failed: \(String(describing: error), privacy: .public)")
        }
        return "found \(files) downloaded file(s) in \(entries.count - files) folder(s)"
    }

    private static func identifier(for url: URL, domainID: NSFileProviderDomainIdentifier) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { id, dom, _ in
                if let id, dom == domainID { cont.resume(returning: id.rawValue) } else { cont.resume(returning: nil) }
            }
        }
    }

    /// Non-dataless regular files and folders, never descending into dataless folders.
    static func walk(_ root: URL) async -> [Found] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Found], Never>) in
            let thread = Thread {
                _ = setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                    IOPOL_SCOPE_THREAD,
                    IOPOL_MATERIALIZE_DATALESS_FILES_OFF
                )
                cont.resume(returning: walkSync(root))
            }
            thread.name = "CryptoMako.FinderPermissionScanner"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func walkSync(_ root: URL) -> [Found] {
        var out: [Found] = []
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return out }
        while let url = walker.nextObject() as? URL {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let dataless = st.st_flags & SpaceReclaimer.datalessFlag != 0
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if url.lastPathComponent == ".Trash" { walker.skipDescendants(); continue }
                if dataless { walker.skipDescendants(); continue }
                out.append(Found(url: url, isDirectory: true, size: 0))
            case S_IFREG:
                if !dataless { out.append(Found(url: url, isDirectory: false, size: Int64(st.st_size))) }
            default:
                continue
            }
        }
        return out
    }
}
