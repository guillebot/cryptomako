import FileProvider
import Foundation

// MARK: - Capabilities

/// Capability sets for CryptoMako File Provider items, kept here (not in the appex)
/// so tests can pin the bits Finder depends on.
///
/// `.allowsEvicting` is what makes Finder show **Remove Download**. Eviction is a
/// purely local operation performed by fileproviderd: it drops the materialized
/// bytes and leaves a dataless placeholder. It never calls `deleteItem` /
/// `modifyItem`, so it cannot delete anything on S3.
public enum FileProviderCapabilitySets {
    /// Regular vault files. No `.allowsTrashing` (Finder Move-to-Trash hit -36);
    /// Delete goes through `deleteItem` → fail-closed remote delete.
    public static var file: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting, .allowsEvicting]
    }

    /// Vault directories. `.allowsEvicting` lets Finder evict a whole folder
    /// recursively (every downloaded file under it goes back to online-only).
    public static var directory: NSFileProviderItemCapabilities {
        [
            .allowsReading,
            .allowsWriting,
            .allowsAddingSubItems,
            .allowsContentEnumerating,
            .allowsDeleting,
            .allowsRenaming,
            .allowsReparenting,
            .allowsEvicting,
        ]
    }

    /// Vault root: not deletable (remoteDelete rejects `.root`), but evictable so
    /// "Remove Download" on the CryptoMako location frees everything.
    public static var root: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsWriting, .allowsAddingSubItems, .allowsContentEnumerating, .allowsEvicting]
    }

    /// Synthetic `.trashContainer` (always empty).
    public static var trashContainer: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
    }

    /// Synthetic `.workingSet` (always empty).
    public static var workingSet: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating]
    }

    /// Prefix folded into every item's metadataVersion. Bump whenever a capability
    /// set changes so FPFS replaces cached items (and Finder's menu) on the next
    /// enumeration. The content version is untouched, so nothing re-downloads.
    public static let metadataRevision = "caps-evict-v4"

    /// Metadata version for a file: revision + ETag (ETag alone never changed when
    /// capabilities did, so Finder kept the old menu).
    public static func fileMetadataVersion(eTag: String?) -> Data {
        Data("\(metadataRevision)|\(eTag ?? "0")".utf8)
    }
}

// MARK: - Eviction policy (pure)

/// Automatic "free up space" policy. Off by default.
public struct AutoEvictionPolicy: Codable, Equatable, Sendable {
    /// Run the policy periodically while the vault is unlocked and mounted.
    public var enabled: Bool
    /// Only evict files not opened for at least this many days (0 = any age).
    public var minDaysSinceAccess: Int
    /// Only evict files at least this large, in megabytes (0 = any size).
    public var minFileSizeMB: Int

    public init(enabled: Bool = false, minDaysSinceAccess: Int = 30, minFileSizeMB: Int = 0) {
        self.enabled = enabled
        self.minDaysSinceAccess = minDaysSinceAccess
        self.minFileSizeMB = minFileSizeMB
    }

    public static let `default` = AutoEvictionPolicy()

    /// Hours between automatic passes.
    public static let intervalHours: Double = 6

    public var clamped: AutoEvictionPolicy {
        var c = self
        c.minDaysSinceAccess = min(max(minDaysSinceAccess, 0), 3650)
        c.minFileSizeMB = min(max(minFileSizeMB, 0), 1_000_000)
        return c
    }

    public var summary: String {
        let c = clamped
        var parts: [String] = []
        parts.append(c.minDaysSinceAccess == 0 ? "any age" : "not opened in \(c.minDaysSinceAccess) day\(c.minDaysSinceAccess == 1 ? "" : "s")")
        if c.minFileSizeMB > 0 { parts.append("≥ \(c.minFileSizeMB) MB") }
        return parts.joined(separator: ", ")
    }
}

/// What the scanner knows about one entry under the CloudStorage folder.
public struct EvictionCandidate: Equatable, Sendable {
    public var isDirectory: Bool
    /// Local bytes present (not a dataless placeholder).
    public var isMaterialized: Bool
    /// `ubiquitousItemIsUploaded` (nil = unknown).
    public var isUploaded: Bool?
    /// `ubiquitousItemIsUploading` (nil = unknown).
    public var isUploading: Bool?
    /// `ubiquitousItemHasUnresolvedConflicts` (nil = unknown).
    public var hasUnresolvedConflicts: Bool?
    /// Local cleartext size in bytes.
    public var fileSize: Int64
    /// Last open/read (content access date), if known.
    public var lastAccess: Date?
    /// Remote check: the ciphertext object exists on S3 and is at least as large as
    /// the cleartext (nil = not checked yet).
    public var verifiedOnRemote: Bool?

    public init(
        isDirectory: Bool = false,
        isMaterialized: Bool = true,
        isUploaded: Bool? = nil,
        isUploading: Bool? = nil,
        hasUnresolvedConflicts: Bool? = nil,
        fileSize: Int64 = 0,
        lastAccess: Date? = nil,
        verifiedOnRemote: Bool? = nil
    ) {
        self.isDirectory = isDirectory
        self.isMaterialized = isMaterialized
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
        self.fileSize = fileSize
        self.lastAccess = lastAccess
        self.verifiedOnRemote = verifiedOnRemote
    }
}

public enum EvictionSkipReason: String, CaseIterable, Sendable {
    case directory
    case notDownloaded
    case uploading
    case notUploaded
    case conflict
    case notOnRemote
    case recentlyOpened
    case belowSizeThreshold

    public var label: String {
        switch self {
        case .directory: "folder"
        case .notDownloaded: "already online-only"
        case .uploading: "uploading"
        case .notUploaded: "not uploaded yet"
        case .conflict: "has conflicts"
        case .notOnRemote: "not verified on vault"
        case .recentlyOpened: "opened recently"
        case .belowSizeThreshold: "below size threshold"
        }
    }
}

public enum EvictionDecision: Equatable, Sendable {
    case evict
    case skip(EvictionSkipReason)
}

public enum FileProviderEvictionPolicy {
    /// Fail-safe decision for one entry. `policy == nil` means a manual
    /// "Free up space" (every safe file); otherwise the automatic thresholds apply.
    ///
    /// Order matters: safety checks (upload state, conflicts, remote proof) come
    /// before the age/size preferences, and an explicit `false` from the remote
    /// check always wins.
    public static func decide(
        _ c: EvictionCandidate,
        policy: AutoEvictionPolicy?,
        now: Date
    ) -> EvictionDecision {
        if c.isDirectory { return .skip(.directory) }
        if !c.isMaterialized { return .skip(.notDownloaded) }
        if c.isUploading == true { return .skip(.uploading) }
        if c.isUploaded == false { return .skip(.notUploaded) }
        if c.hasUnresolvedConflicts == true { return .skip(.conflict) }
        if let policy {
            let p = policy.clamped
            if p.minFileSizeMB > 0, c.fileSize < Int64(p.minFileSizeMB) * 1_000_000 {
                return .skip(.belowSizeThreshold)
            }
            if p.minDaysSinceAccess > 0 {
                // Unknown access date counts as "recent" (fail-safe: keep it).
                guard let last = c.lastAccess else { return .skip(.recentlyOpened) }
                let age = now.timeIntervalSince(last)
                if age < Double(p.minDaysSinceAccess) * 86_400 { return .skip(.recentlyOpened) }
            }
        }
        if c.verifiedOnRemote == false { return .skip(.notOnRemote) }
        return .evict
    }

    /// Cryptomator ciphertext is always larger than its cleartext (68-byte header
    /// plus 28 bytes per 32 KiB chunk). A remote object smaller than the local file
    /// means a partial/missing upload — never evict in that case.
    public static func remoteCovers(localCleartextBytes: Int64, remoteCiphertextBytes: Int64?) -> Bool {
        guard let remote = remoteCiphertextBytes else { return false }
        return remote >= localCleartextBytes
    }
}

/// Running/final tally for a "Free up space" pass.
public struct EvictionSummary: Equatable, Sendable {
    public var scannedFiles = 0
    public var evictedFiles = 0
    public var bytesFreed: Int64 = 0
    public var failed = 0
    public var skipped: [EvictionSkipReason: Int] = [:]
    public var firstError: String?

    public init() {}

    public mutating func recordSkip(_ reason: EvictionSkipReason) {
        skipped[reason, default: 0] += 1
    }

    public var skippedTotal: Int { skipped.values.reduce(0, +) }

    /// One-line human summary, e.g. "Freed 12.3 GB — 1,204 files online-only; skipped 3 (uploading 3)".
    public func line(formatBytes: (Int64) -> String) -> String {
        var s = "Freed \(formatBytes(bytesFreed)) — \(evictedFiles) file\(evictedFiles == 1 ? "" : "s") now online-only"
        let shown = EvictionSkipReason.allCases.compactMap { r -> String? in
            guard r != .notDownloaded, r != .directory, let n = skipped[r], n > 0 else { return nil }
            return "\(r.label) \(n)"
        }
        if !shown.isEmpty {
            s += "; kept \(shown.joined(separator: ", "))"
        }
        if failed > 0 {
            s += "; \(failed) failed"
            if let firstError { s += " (\(firstError))" }
        }
        return s
    }
}

// MARK: - Working-set capability refresh (pure)

/// One-time refresh that pushes current capabilities onto items the system already
/// stores on disk.
///
/// With `NSFileProviderReplicatedExtension`, fileproviderd only asks for changes
/// through the **working set** enumerator: per-folder `enumerateChanges` is never
/// called, and `signalEnumerator` ignores every container but `.workingSet`. Our
/// working set used to be permanently empty with a fixed anchor, so a capability or
/// metadata-revision bump only reached items when a folder was enumerated from
/// scratch. Items that were already known (every materialized file) kept their old
/// capabilities forever. That is why 1.0.17 files had no `.allowsEvicting` and
/// Finder showed no Remove Download.
///
/// Since 1.0.19 *whether* to refresh comes from `CapabilityRefreshState` (app group),
/// not the anchor: fileproviderd adopted the 1.0.18 anchor via `currentSyncAnchor`
/// without asking for changes, so anchor-only detection never fired. Anchors below
/// are still used for paging. Originally: the working-set sync anchor encodes `metadataRevision`. When the system asks
/// for changes from an older anchor, the extension reports `didUpdate` for every
/// materialized item (from remote truth, same content version → metadata only, no
/// re-download, local edits untouched) and moves the anchor to the current one.
public enum WorkingSetRefresh {
    /// Anchor the working set reports once every stored item carries the current revision.
    public static var currentAnchor: Data {
        Data("ws|\(FileProviderCapabilitySets.metadataRevision)".utf8)
    }

    /// Prefix for an in-progress (paged) refresh anchor: `wsp|<revision>|<nextGroup>`.
    static let partialPrefix = "wsp|"

    public enum AnchorState: Equatable, Sendable {
        /// Nothing to report.
        case current
        /// Refresh needed, starting at group 0 (legacy `empty` anchor, older revision, garbage).
        case stale
        /// Paged refresh of the current revision in progress; resume at this group.
        case partial(nextGroup: Int)
    }

    public static func partialAnchor(nextGroup: Int) -> Data {
        Data("\(partialPrefix)\(FileProviderCapabilitySets.metadataRevision)|\(nextGroup)".utf8)
    }

    public static func state(of anchor: Data) -> AnchorState {
        if anchor == currentAnchor { return .current }
        guard let s = String(data: anchor, encoding: .utf8), s.hasPrefix(partialPrefix) else {
            return .stale
        }
        let parts = s.dropFirst(partialPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              String(parts[0]) == FileProviderCapabilitySets.metadataRevision,
              let next = Int(parts[1]), next >= 0
        else { return .stale }
        return .partial(nextGroup: next)
    }

    /// Parent directories listed per `enumerateChanges` page.
    public static let groupsPerPage = 40

    public enum ItemKind: Equatable, Sendable {
        case root
        case directory
        case file
    }

    /// Metadata version an up-to-date item of this kind carries.
    public static func expectedMetadataVersion(kind: ItemKind, contentVersion: Data?) -> Data {
        switch kind {
        case .root, .directory:
            return Data(FileProviderCapabilitySets.metadataRevision.utf8)
        case .file:
            let eTag = contentVersion.flatMap { String(data: $0, encoding: .utf8) }
            return FileProviderCapabilitySets.fileMetadataVersion(eTag: eTag)
        }
    }

    /// Fail-safe filter for a materialized item seen by the system.
    ///
    /// - Skips items in flight or in conflict (they get fresh capabilities from
    ///   `createItem` / `modifyItem` when the upload lands; nothing to evict anyway).
    /// - Skips dataless files (nothing to evict; avoids listing 300k placeholders).
    /// - Skips items that already carry `.allowsEvicting` **and** the current metadata.
    public static func needsRefresh(
        kind: ItemKind?,
        isDownloaded: Bool?,
        isUploaded: Bool?,
        isUploading: Bool?,
        hasUnresolvedConflicts: Bool?,
        capabilities: NSFileProviderItemCapabilities?,
        metadataVersion: Data?,
        contentVersion: Data?
    ) -> Bool {
        guard let kind else { return false }
        if isUploading == true || isUploaded == false || hasUnresolvedConflicts == true { return false }
        if isDownloaded == false { return false }
        let capsOK = capabilities?.contains(.allowsEvicting) ?? false
        let metaOK = metadataVersion.map { $0 == expectedMetadataVersion(kind: kind, contentVersion: contentVersion) } ?? false
        return !(capsOK && metaOK)
    }
}

// MARK: - evictItem errors (pure)

public enum EvictionErrorExplainer {
    /// Human-readable reason for a failed `evictItem`, with the raw domain/code so a
    /// bug report is actionable.
    public static func describe(domain: String, code: Int, localized: String) -> String {
        let raw = "\(domain) \(code)"
        if domain == NSFileProviderErrorDomain {
            switch code {
            case NSFileProviderError.Code.noSuchItem.rawValue:
                return "Finder no longer knows this file — it may have been moved or deleted (\(raw))"
            case NSFileProviderError.Code.notAuthenticated.rawValue:
                return "vault is locked — unlock CryptoMako and retry (\(raw))"
            case NSFileProviderError.Code.unsyncedEdits.rawValue:
                return "file has edits not uploaded yet (\(raw))"
            default:
                break
            }
        }
        if isCapabilityRefusal(domain: domain, code: code) {
            return "Finder has not picked up the Remove Download permission for this file yet. "
                + "CryptoMako refreshes it automatically after an upgrade (unlock the vault and give it a few minutes), then retry (\(raw): \(localized))"
        }
        return "\(localized) (\(raw))"
    }

    /// Errors fileproviderd uses when an item's capabilities forbid the operation.
    public static func isCapabilityRefusal(domain: String, code: Int) -> Bool {
        switch domain {
        case NSCocoaErrorDomain:
            // NSFeatureUnsupportedError, NSFileWriteNoPermissionError, NSFileReadNoPermissionError
            return code == 3328 || code == 513 || code == 257
        case NSPOSIXErrorDomain:
            return code == Int(EPERM) || code == Int(EACCES) || code == Int(ENOTSUP)
        default:
            return false
        }
    }
}

extension EvictionSummary {
    /// Number of consecutive failures (with nothing evicted) after which a pass stops
    /// instead of grinding through thousands of identical errors.
    public static let earlyAbortFailures = 25

    /// True when every attempt so far failed and there have been enough of them.
    public var shouldAbortEarly: Bool {
        evictedFiles == 0 && failed >= Self.earlyAbortFailures
    }
}

// MARK: - Cryptomator sizes (pure)

public enum CryptomatorSize {
    static let headerBytes: Int64 = 68
    static let chunkPayload: Int64 = 32_768
    static let chunkOverhead: Int64 = 28

    /// Cleartext size of a format-8 (GCM) file from its ciphertext object size,
    /// or nil when the size cannot be a valid ciphertext.
    public static func cleartextSize(ciphertext: Int64) -> Int64? {
        guard ciphertext >= headerBytes else { return nil }
        let body = ciphertext - headerBytes
        if body == 0 { return 0 }
        let fullChunk = chunkPayload + chunkOverhead
        let chunks = (body + fullChunk - 1) / fullChunk
        let clear = body - chunks * chunkOverhead
        // The last chunk must carry at least one byte.
        guard clear > (chunks - 1) * chunkPayload else { return nil }
        return clear
    }

    public static func ciphertextSize(cleartext: Int64) -> Int64 {
        guard cleartext > 0 else { return headerBytes }
        let chunks = (cleartext + chunkPayload - 1) / chunkPayload
        return headerBytes + cleartext + chunks * chunkOverhead
    }
}
