using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

/// <summary>App-wide preferences (proxy, Sync bandwidth). Non-secret. Platforms-locked keys.</summary>
public sealed class AppPreferences
{
    [JsonPropertyName("proxyMode")]
    public string ProxyMode { get; set; } = "system"; // system | direct | custom

    [JsonPropertyName("proxyHost")]
    public string ProxyHost { get; set; } = "";

    [JsonPropertyName("proxyPort")]
    public int ProxyPort { get; set; } = 8080;

    [JsonPropertyName("proxyUsername")]
    public string ProxyUsername { get; set; } = "";

    /// <summary>
    /// Platforms-locked key <c>backupTransferMode</c>: <c>backup</c> | <c>sync</c>.
    /// Default <c>backup</c> (safer: put/update only, no vault deletes).
    /// <c>sync</c> = same puts plus delete vault ciphertext orphans under that source's
    /// <c>Backups/&lt;folder&gt;/</c> only. Never deletes the local source.
    /// </summary>
    [JsonPropertyName("backupTransferMode")]
    public string BackupTransferMode { get; set; } = BackupTransferModeBackup;

    public const string BackupTransferModeBackup = "backup";
    public const string BackupTransferModeSync = "sync";

    [JsonPropertyName("limitSyncUploadBandwidth")]
    public bool LimitSyncUploadBandwidth { get; set; }

    [JsonPropertyName("syncUploadCapMbps")]
    public double SyncUploadCapMbps { get; set; } = 50;

    [JsonPropertyName("syncSmallPutConcurrency")]
    public int SyncSmallPutConcurrency { get; set; } = 96;

    [JsonPropertyName("syncMediumPutConcurrency")]
    public int SyncMediumPutConcurrency { get; set; } = 32;

    [JsonPropertyName("syncLargePutConcurrency")]
    public int SyncLargePutConcurrency { get; set; } = 4;

    public void ClampSyncWorkers()
    {
        SyncSmallPutConcurrency = Math.Clamp(SyncSmallPutConcurrency, 1, 256);
        SyncMediumPutConcurrency = Math.Clamp(SyncMediumPutConcurrency, 1, 128);
        SyncLargePutConcurrency = Math.Clamp(SyncLargePutConcurrency, 1, 16);
        if (SyncUploadCapMbps < 1) SyncUploadCapMbps = 1;
    }

    public int ClampedSmallPutConcurrency => Math.Clamp(SyncSmallPutConcurrency, 1, 256);
    public int ClampedMediumPutConcurrency => Math.Clamp(SyncMediumPutConcurrency, 1, 128);
    public int ClampedLargePutConcurrency => Math.Clamp(SyncLargePutConcurrency, 1, 16);

    /// <summary>Bytes/sec target for Sync pacing, or null when unlimited.</summary>
    public double? SyncUploadBytesPerSecond
    {
        get
        {
            if (!LimitSyncUploadBandwidth || SyncUploadCapMbps <= 0) return null;
            var mbps = Math.Max(1, SyncUploadCapMbps);
            return mbps * 1_000_000 / 8;
        }
    }

    /// <summary>
    /// Returns <c>sync</c> only for that exact mode (case-insensitive); anything else
    /// (empty, unknown) fails closed to <c>backup</c> (no vault deletes).
    /// </summary>
    public static string NormalizeBackupTransferMode(string? mode)
    {
        if (string.Equals(mode?.Trim(), BackupTransferModeSync, StringComparison.OrdinalIgnoreCase))
            return BackupTransferModeSync;
        return BackupTransferModeBackup;
    }

    public bool IsSyncTransferMode =>
        NormalizeBackupTransferMode(BackupTransferMode) == BackupTransferModeSync;

    public static AppPreferences Deserialize(string json)
    {
        var p = JsonSerializer.Deserialize<AppPreferences>(json, VaultSettings.JsonOptions) ?? new AppPreferences();
        p.BackupTransferMode = NormalizeBackupTransferMode(p.BackupTransferMode);
        return p;
    }

    public string Serialize()
    {
        var copy = new AppPreferences
        {
            ProxyMode = ProxyMode,
            ProxyHost = ProxyHost,
            ProxyPort = ProxyPort,
            ProxyUsername = ProxyUsername,
            BackupTransferMode = NormalizeBackupTransferMode(BackupTransferMode),
            LimitSyncUploadBandwidth = LimitSyncUploadBandwidth,
            SyncUploadCapMbps = SyncUploadCapMbps,
            SyncSmallPutConcurrency = SyncSmallPutConcurrency,
            SyncMediumPutConcurrency = SyncMediumPutConcurrency,
            SyncLargePutConcurrency = SyncLargePutConcurrency,
        };
        copy.ClampSyncWorkers();
        return JsonSerializer.Serialize(copy, VaultSettings.JsonOptions);
    }
}
