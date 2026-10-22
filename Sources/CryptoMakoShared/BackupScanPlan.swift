import Foundation

/// One file that the scan decided must be uploaded. Only what a put needs:
/// relative path (the local URL is rebuilt from the source root), size, mtime.
/// No file contents, no URL, no resolved vault dir — millions of these must fit.
public struct BackupPendingUpload: Equatable, Sendable {
    public let relativePath: String
    public let size: Int64
    public let contentModification: Date

    public init(relativePath: String, size: Int64, contentModification: Date) {
        self.relativePath = relativePath
        self.size = size
        self.contentModification = contentModification
    }

    /// Folder of this file relative to the source root ("" = root).
    public var parentRelativePath: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

public enum BackupUploadTier: Equatable, Sendable {
    case small
    case medium
    case large
}

public struct BackupScanCount: Equatable, Sendable {
    public var files: Int
    public var bytes: Int64

    public init(files: Int = 0, bytes: Int64 = 0) {
        self.files = files
        self.bytes = bytes
    }

    public mutating func add(bytes: Int64) {
        files += 1
        self.bytes += bytes
    }
}

/// Everything the Backup scan phase produces, kept apart from the upload phase.
///
/// The scan only records local metadata and the skip decision. Nothing here
/// touches S3, the vault, or file contents, and nothing here blocks: a put is
/// never started while a plan is still being filled. Once `finish()` is called
/// the plan is frozen and the upload phase consumes it — `toUpload` is what the
/// UI shows as "still to transfer" before the first put runs.
public struct BackupScanPlan: Sendable {
    public let mediumThreshold: Int64
    public let largeThreshold: Int64

    public private(set) var small: [BackupPendingUpload] = []
    public private(set) var medium: [BackupPendingUpload] = []
    public private(set) var large: [BackupPendingUpload] = []

    public private(set) var discovered = BackupScanCount()
    public private(set) var skipped = BackupScanCount()
    public private(set) var toUpload = BackupScanCount()
    public private(set) var isFinished = false

    public init(mediumThreshold: Int64, largeThreshold: Int64) {
        self.mediumThreshold = mediumThreshold
        self.largeThreshold = max(largeThreshold, mediumThreshold)
    }

    public func tier(forSize size: Int64) -> BackupUploadTier {
        if size >= largeThreshold { return .large }
        if size >= mediumThreshold { return .medium }
        return .small
    }

    /// Record one eligible regular file (excludes already applied). Pure: no I/O.
    @discardableResult
    public mutating func record(
        relativePath: String,
        size: Int64,
        contentModification: Date,
        indexed: BackupFileFingerprint?
    ) -> BackupWalkFileAction {
        precondition(!isFinished, "scan plan already finished")
        discovered.add(bytes: size)
        let step = BackupWalkSkipPolicy.step(
            indexed: indexed,
            size: size,
            contentModification: contentModification
        )
        switch step.action {
        case .skipUnchanged:
            skipped.add(bytes: size)
        case .enqueueUpload:
            toUpload.add(bytes: size)
            let job = BackupPendingUpload(
                relativePath: relativePath,
                size: size,
                contentModification: contentModification
            )
            switch tier(forSize: size) {
            case .large: large.append(job)
            case .medium: medium.append(job)
            case .small: small.append(job)
            }
        }
        return step.action
    }

    /// Freeze the plan. Uploads may only read a finished plan.
    public mutating func finish() {
        isFinished = true
    }

    public var pendingCount: Int { small.count + medium.count + large.count }
}
