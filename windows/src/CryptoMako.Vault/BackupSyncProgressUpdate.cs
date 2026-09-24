namespace CryptoMako.Vault;

/// <summary>Structured Backup Sync progress for WinUI/macOS-parity meters.</summary>
public sealed class BackupSyncProgressUpdate
{
    public string Phase { get; init; } = "";
    public int FilesDone { get; init; }
    public int FilesTotal { get; init; }
    public long BytesDone { get; init; }
    public long BytesTotal { get; init; }
    public double BytesPerSecond { get; init; }
    public string? CurrentPath { get; init; }

    /// <summary>0–100 based on bytes when known, else files.</summary>
    public double Percent
    {
        get
        {
            if (BytesTotal > 0)
                return Math.Min(100, 100.0 * BytesDone / BytesTotal);
            if (FilesTotal > 0)
                return Math.Min(100, 100.0 * FilesDone / FilesTotal);
            return 0;
        }
    }
}
