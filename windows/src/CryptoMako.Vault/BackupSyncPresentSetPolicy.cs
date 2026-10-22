namespace CryptoMako.Vault;

/// <summary>
/// Sync orphan prune allow-set vs upload eligibility for one on-disk regular file.
/// Mirrors <c>Sources/CryptoMakoShared/BackupSyncPresentSetPolicy.swift</c>.
/// </summary>
public enum BackupSyncScanDisposition
{
    /// <summary>On disk for prune; may go through fingerprint / upload decision.</summary>
    PresentUploadEligible,

    /// <summary>On disk for prune; must not upload (excluded or hidden).</summary>
    PresentDoNotUpload,
}

public static class BackupSyncPresentSetPolicy
{
    public static BackupSyncScanDisposition Disposition(bool isHidden, bool isExcluded)
    {
        if (isHidden || isExcluded)
            return BackupSyncScanDisposition.PresentDoNotUpload;
        return BackupSyncScanDisposition.PresentUploadEligible;
    }

    /// <summary>
    /// Sync mode retains every path present on disk (including excluded/hidden).
    /// Backup mode does not retain a present-set (prune does not run).
    /// </summary>
    public static bool RetainInPruneAllowSet(bool isSyncMode, bool pathPresentOnDisk)
        => isSyncMode && pathPresentOnDisk;
}
