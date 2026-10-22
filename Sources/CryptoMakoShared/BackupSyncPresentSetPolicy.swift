import Foundation

/// Sync orphan prune allow-set vs upload eligibility for one on-disk regular file.
///
/// Prune must treat "present on disk" separately from "eligible to upload".
/// Excluded and hidden paths stay in the allow-set so Sync does not delete their
/// vault ciphertext; they must never be uploaded.
public enum BackupSyncScanDisposition: Equatable, Sendable {
    /// On disk for prune; may go through fingerprint / upload decision.
    case presentUploadEligible
    /// On disk for prune; must not upload (excluded or hidden).
    case presentDoNotUpload
}

public enum BackupSyncPresentSetPolicy: Sendable {
    /// Pure policy for a path that exists under the source root.
    public static func disposition(isHidden: Bool, isExcluded: Bool) -> BackupSyncScanDisposition {
        if isHidden || isExcluded {
            return .presentDoNotUpload
        }
        return .presentUploadEligible
    }

    /// Sync mode retains every path that is present on disk (including excluded/hidden).
    /// Backup mode does not retain a present-set (prune does not run).
    public static func retainInPruneAllowSet(isSyncMode: Bool, pathPresentOnDisk: Bool) -> Bool {
        isSyncMode && pathPresentOnDisk
    }
}
