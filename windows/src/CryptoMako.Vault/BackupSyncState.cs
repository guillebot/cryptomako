using System.Text.Json;

namespace CryptoMako.Vault;

public sealed class BackupFileFingerprint
{
    public long Size { get; set; }
    public long ContentModificationUtcTicks { get; set; }

    public bool Matches(long size, DateTimeOffset mtimeUtc) =>
        Size == size && Math.Abs(ContentModificationUtcTicks - mtimeUtc.UtcTicks) < TimeSpan.TicksPerMillisecond;
}

/// <summary>Local index of successfully synced files (mtime + size). Best-effort persistence.</summary>
public sealed class BackupSyncState
{
    public Dictionary<string, BackupFileFingerprint> Files { get; set; } = new(StringComparer.Ordinal);

    public static string Key(string vaultFolder, string relativePath) => $"{vaultFolder}/{relativePath}";

    public static BackupSyncState LoadFromFile(string path)
    {
        if (!File.Exists(path)) return new BackupSyncState();
        try
        {
            return JsonSerializer.Deserialize<BackupSyncState>(File.ReadAllText(path), VaultSettings.JsonOptions)
                ?? new BackupSyncState();
        }
        catch
        {
            return new BackupSyncState();
        }
    }

    public void SaveToFile(string path)
    {
        try
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);
            File.WriteAllText(path, JsonSerializer.Serialize(this, VaultSettings.JsonOptions));
        }
        catch
        {
            // Best-effort; never fail a sync because the index could not persist.
        }
    }
}
