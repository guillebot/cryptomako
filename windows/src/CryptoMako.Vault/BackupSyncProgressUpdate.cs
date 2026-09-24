namespace CryptoMako.Vault;

/// <summary>Structured Backup Sync progress for WinUI/macOS-parity meters.</summary>
public sealed class BackupSyncProgressUpdate
{
    public string Phase { get; init; } = "";
    public int FilesDone { get; init; }
    public int FilesTotal { get; init; }
    /// <summary>Files already up-to-date (skipped by fingerprint) in this scan.</summary>
    public int FilesSkipped { get; init; }
    /// <summary>Files seen under the source tree (to-upload + skipped).</summary>
    public int FilesScanned { get; init; }
    public long BytesDone { get; init; }
    public long BytesTotal { get; init; }
    /// <summary>Total bytes of scanned regular files (upload queue + skipped).</summary>
    public long BytesScanned { get; init; }
    public double BytesPerSecond { get; init; }
    public string? CurrentPath { get; init; }

    /// <summary>0-100 based on bytes when known, else files. 100 when all skipped.</summary>
    public double Percent
    {
        get
        {
            if (BytesTotal > 0)
                return Math.Min(100, 100.0 * BytesDone / BytesTotal);
            if (FilesTotal > 0)
                return Math.Min(100, 100.0 * FilesDone / FilesTotal);
            if (FilesScanned > 0 && FilesSkipped >= FilesScanned)
                return 100;
            return 0;
        }
    }
}
