import CryptoMakoShared
import CryptoMakoVault
import Darwin
import FileProvider
import Foundation
import OSLog

private let reclaimLog = Logger(subsystem: "net.gschimmel.cryptomako", category: "SpaceReclaimer")

/// "Free up space": make downloaded vault files online-only again by asking
/// fileproviderd to evict them (`NSFileProviderManager.evictItem`).
///
/// Eviction is local: it drops materialized bytes and leaves a dataless
/// placeholder. It never reaches the extension's `deleteItem` / `modifyItem`, so
/// nothing on S3 is touched. Fail-safe rules on top of the system's own checks
/// (fileproviderd already refuses items with unsynced edits):
/// - skip files that are uploading, not uploaded, or in conflict;
/// - skip files whose ciphertext is not on the vault (listed on S3, size ≥ cleartext);
/// - never descend into dataless folders, and scan with dataless materialization
///   turned off for the scanning thread, so the walk cannot trigger downloads or
///   remote listings.
@MainActor
final class SpaceReclaimer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(entries: Int)
        case evicting(done: Int, total: Int, bytesFreed: Int64)
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastRunAt: Date?

    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    var isRunning: Bool {
        switch phase {
        case .scanning, .evicting: true
        default: false
        }
    }

    var statusLine: String? {
        switch phase {
        case .idle: return nil
        case .scanning(let n): return "Free up space: scanning downloaded files… (\(n) entries checked)"
        case .evicting(let done, let total, let bytes):
            return "Free up space: \(done)/\(total) files — \(TransferSnapshot.formatBytes(bytes)) freed so far"
        case .finished(let s): return s
        case .failed(let s): return "Free up space failed: \(s)"
        }
    }

    func cancel() {
        cancelFlag.set()
    }

    func clearStatus() {
        if !isRunning { phase = .idle }
    }

    /// - Parameters:
    ///   - folder: a folder (or file) inside the CryptoMako CloudStorage location;
    ///     `nil` = the whole vault root.
    ///   - policy: `nil` for a manual pass (every safe file), or the automatic thresholds.
    func run(
        folder: URL?,
        policy: AutoEvictionPolicy?,
        domain: NSFileProviderDomain,
        session: VaultSession,
        label: String
    ) {
        guard !isRunning else { return }
        cancelFlag.reset()
        phase = .scanning(entries: 0)
        let cancelFlag = self.cancelFlag
        task = Task { [weak self] in
            do {
                guard let manager = NSFileProviderManager(for: domain) else {
                    throw ReclaimError.message("CryptoMako is not mounted in Finder")
                }
                // Nudge the working-set capability refresh (no-op once current) so
                // items Finder still holds with pre-1.0.18 capabilities get
                // .allowsEvicting before/while we evict.
                try? await manager.signalEnumerator(for: .workingSet)
                let root = try await manager.getUserVisibleURL(for: .rootContainer)
                    .standardizedFileURL.resolvingSymlinksInPath()
                let target = (folder ?? root).standardizedFileURL.resolvingSymlinksInPath()
                guard Self.isInside(target, root: root) else {
                    throw ReclaimError.message("Pick a folder inside the CryptoMako Finder location (\(root.path))")
                }

                let scan = await Self.scan(target, cancel: cancelFlag) { n in
                    Task { @MainActor in self?.phase = .scanning(entries: n) }
                }
                var summary = scan.summary
                let now = Date()
                var eligible: [ScannedFile] = []
                for f in scan.files {
                    switch FileProviderEvictionPolicy.decide(f.candidate, policy: policy, now: now) {
                    case .evict: eligible.append(f)
                    case .skip(let r): summary.recordSkip(r)
                    }
                }
                let total = eligible.count
                await MainActor.run { self?.phase = .evicting(done: 0, total: total, bytesFreed: 0) }

                let verifier = RemoteVerifier(session: session)
                var done = 0
                for f in eligible {
                    if cancelFlag.isSet { break }
                    let outcome = await Self.evictOne(
                        f,
                        manager: manager,
                        domainID: domain.identifier,
                        verifier: verifier,
                        policy: policy,
                        now: now
                    )
                    switch outcome {
                    case .evicted(let bytes):
                        summary.evictedFiles += 1
                        summary.bytesFreed += bytes
                    case .skipped(let r):
                        summary.recordSkip(r)
                    case .failed(let msg):
                        summary.failed += 1
                        if summary.firstError == nil { summary.firstError = msg }
                        reclaimLog.error("evict failed: \(msg, privacy: .public)")
                    }
                    if summary.shouldAbortEarly {
                        let reason = summary.firstError ?? "unknown error"
                        reclaimLog.error("reclaim aborted after \(summary.failed) failures, nothing evicted")
                        throw ReclaimError.message(
                            "stopped after \(summary.failed) files failed and none were freed. First error: \(reason)"
                        )
                    }
                    done += 1
                    if done % 25 == 0 || done == total {
                        let snapshot = summary.bytesFreed
                        await MainActor.run { self?.phase = .evicting(done: done, total: total, bytesFreed: snapshot) }
                    }
                }
                var line = "\(label): " + summary.line(formatBytes: TransferSnapshot.formatBytes)
                if cancelFlag.isSet { line += " (cancelled)" }
                reclaimLog.info("reclaim done evicted=\(summary.evictedFiles) freed=\(summary.bytesFreed) failed=\(summary.failed) skipped=\(summary.skippedTotal)")
                await MainActor.run {
                    self?.phase = .finished(line)
                    self?.lastRunAt = Date()
                }
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Scan (dedicated thread, no materialization)

    struct ScannedFile: Sendable {
        let url: URL
        let allocatedBytes: Int64
        var candidate: EvictionCandidate
    }

    struct ScanResult: Sendable {
        var files: [ScannedFile] = []
        var summary = EvictionSummary()
    }

    nonisolated static func isInside(_ url: URL, root: URL) -> Bool {
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(r)
    }

    /// `SF_DATALESS` from <sys/stat.h>: placeholder with no local bytes.
    nonisolated static let datalessFlag: UInt32 = 0x4000_0000

    nonisolated static func scan(
        _ target: URL,
        cancel: CancelFlag,
        progress: @escaping @Sendable (Int) -> Void
    ) async -> ScanResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ScanResult, Never>) in
            let thread = Thread {
                // This thread must never trigger downloads or remote listings.
                _ = setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                    IOPOL_SCOPE_THREAD,
                    IOPOL_MATERIALIZE_DATALESS_FILES_OFF
                )
                cont.resume(returning: scanSync(target, cancel: cancel, progress: progress))
            }
            thread.name = "CryptoMako.SpaceReclaimer.scan"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    nonisolated private static func scanSync(
        _ target: URL,
        cancel: CancelFlag,
        progress: (Int) -> Void
    ) -> ScanResult {
        var result = ScanResult()
        let keys: [URLResourceKey] = [
            .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
            .fileSizeKey,
            .contentAccessDateKey,
        ]
        func consider(_ url: URL, _ st: stat) {
            result.summary.scannedFiles += 1
            if st.st_flags & datalessFlag != 0 {
                result.summary.recordSkip(.notDownloaded)
                return
            }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(v?.fileSize ?? Int(st.st_size))
            let candidate = EvictionCandidate(
                isDirectory: false,
                isMaterialized: true,
                isUploaded: v?.ubiquitousItemIsUploaded,
                isUploading: v?.ubiquitousItemIsUploading,
                hasUnresolvedConflicts: v?.ubiquitousItemHasUnresolvedConflicts,
                fileSize: size,
                lastAccess: v?.contentAccessDate,
                verifiedOnRemote: nil
            )
            result.files.append(ScannedFile(url: url, allocatedBytes: Int64(st.st_blocks) * 512, candidate: candidate))
        }

        var st = stat()
        guard lstat(target.path, &st) == 0 else { return result }
        if (st.st_mode & S_IFMT) == S_IFREG {
            consider(target, st)
            return result
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_flags & datalessFlag == 0 else {
            return result
        }
        guard let walker = FileManager.default.enumerator(
            at: target,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return result }

        var entries = 0
        while let url = walker.nextObject() as? URL {
            if cancel.isSet { break }
            entries += 1
            if entries % 2_000 == 0 { progress(entries) }
            var s = stat()
            guard lstat(url.path, &s) == 0 else { continue }
            switch s.st_mode & S_IFMT {
            case S_IFDIR:
                // Dataless folder: never listed locally — nothing downloaded below it.
                if s.st_flags & datalessFlag != 0 { walker.skipDescendants() }
            case S_IFREG:
                consider(url, s)
            default:
                continue
            }
        }
        progress(entries)
        return result
    }

    // MARK: - Evict

    enum Outcome {
        case evicted(Int64)
        case skipped(EvictionSkipReason)
        case failed(String)
    }

    nonisolated private static func evictOne(
        _ f: ScannedFile,
        manager: NSFileProviderManager,
        domainID: NSFileProviderDomainIdentifier,
        verifier: RemoteVerifier,
        policy: AutoEvictionPolicy?,
        now: Date
    ) async -> Outcome {
        let identifier: NSFileProviderItemIdentifier
        do {
            let (id, dom) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier), Error>) in
                NSFileProviderManager.getIdentifierForUserVisibleFile(at: f.url) { id, dom, error in
                    if let id, let dom {
                        cont.resume(returning: (id, dom))
                    } else {
                        cont.resume(throwing: error ?? NSFileProviderError(.noSuchItem))
                    }
                }
            }
            guard dom == domainID else { return .skipped(.notOnRemote) }
            identifier = id
        } catch {
            let ns = error as NSError
            return .failed(
                "could not resolve the Finder item: "
                    + EvictionErrorExplainer.describe(domain: ns.domain, code: ns.code, localized: ns.localizedDescription)
            )
        }
        guard case .file(let parentDirId, let cipherName)? = ItemIdentifier(rawValue: identifier.rawValue) else {
            return .skipped(.notOnRemote)
        }
        var candidate = f.candidate
        candidate.verifiedOnRemote = await verifier.verify(
            parentDirId: parentDirId,
            cipherName: cipherName,
            localCleartextBytes: candidate.fileSize
        )
        if case .skip(let r) = FileProviderEvictionPolicy.decide(candidate, policy: policy, now: now) {
            return .skipped(r)
        }
        // `decide` lets nil through only for unknown; remote proof is mandatory here.
        guard candidate.verifiedOnRemote == true else { return .skipped(.notOnRemote) }
        do {
            try await manager.evictItem(identifier: identifier)
        } catch {
            let ns = error as NSError
            if ns.domain == NSFileProviderErrorDomain,
               ns.code == NSFileProviderError.Code.unsyncedEdits.rawValue {
                return .skipped(.notUploaded)
            }
            return .failed(
                EvictionErrorExplainer.describe(domain: ns.domain, code: ns.code, localized: ns.localizedDescription)
            )
        }
        var s = stat()
        if lstat(f.url.path, &s) == 0, s.st_flags & datalessFlag == 0 {
            // fileproviderd accepted but bytes are still there (e.g. reopened) — count 0.
            return .evicted(0)
        }
        return .evicted(f.allocatedBytes)
    }

    enum ReclaimError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }
}

/// Thread-safe cancel flag shared with the scan thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// Lists each parent directory once and checks the ciphertext object is on S3.
actor RemoteVerifier {
    private let session: VaultSession
    private var cache: [String: [String: Int64?]] = [:]
    private var failedDirs: Set<String> = []

    init(session: VaultSession) {
        self.session = session
    }

    func verify(parentDirId: String, cipherName: String, localCleartextBytes: Int64) async -> Bool {
        if failedDirs.contains(parentDirId) { return false }
        if cache[parentDirId] == nil {
            do {
                let nodes = try await session.list(dirId: parentDirId)
                var map: [String: Int64?] = [:]
                for n in nodes where n.kind == .file {
                    map[n.cipherName] = n.size
                }
                cache[parentDirId] = map
            } catch {
                failedDirs.insert(parentDirId)
                return false
            }
        }
        guard let entry = cache[parentDirId]?[cipherName] else { return false }
        return FileProviderEvictionPolicy.remoteCovers(
            localCleartextBytes: localCleartextBytes,
            remoteCiphertextBytes: entry
        )
    }
}
