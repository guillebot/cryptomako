namespace CryptoMako.Vault;

/// <summary>Structured Backup Sync progress for WinUI/macOS-parity meters.</summary>
public sealed class BackupSyncProgressUpdate
{
    public string Phase { get; init; } = "";
    /// <summary>Cleartext bytes uploaded so far (skips do not count).</summary>
    public int FilesDone { get; init; }
    /// <summary>Files still to upload after the scan (skips excluded).</summary>
    public int FilesTotal { get; init; }
    /// <summary>Files already up-to-date (skipped by fingerprint) in this scan.</summary>
    public int FilesSkipped { get; init; }
    /// <summary>Files seen under the source tree (to-upload + skipped).</summary>
    public int FilesScanned { get; init; }
    /// <summary>Cleartext bytes uploaded so far.</summary>
    public long BytesDone { get; init; }
    /// <summary>Bytes still to upload after the scan (denominator for percent).</summary>
    public long BytesTotal { get; init; }
    /// <summary>Total bytes of scanned regular files (upload queue + skipped).</summary>
    public long BytesScanned { get; init; }
    public double BytesPerSecond { get; init; }
    public string? CurrentPath { get; init; }
    /// <summary>Vault ciphertext items removed in Sync-mode orphan prune. Always 0 in Backup mode.</summary>
    public int FilesDeleted { get; init; }
    /// <summary>True once the local scan finished (upload percent becomes determinate).</summary>
    public bool WalkFinished { get; init; }

    /// <summary>
    /// 0-100 from uploaded / to-upload after the scan. 0 while scanning
    /// (no stuck percent). 100 when the to-upload set is empty.
    /// </summary>
    public double Percent
    {
        get
        {
            if (Phase == "scanning" || !WalkFinished)
                return 0;
            var frac = BackupUploadProgress.Fraction(WalkFinished, BytesDone, BytesTotal);
            return (frac ?? 0) * 100;
        }
    }
}
