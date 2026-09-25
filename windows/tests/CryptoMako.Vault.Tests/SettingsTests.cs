using System.Text.Json;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class SettingsTests
{
    [Fact]
    public void VaultSettings_round_trip_locked_keys_and_prefix_slash()
    {
        var s = new VaultSettings
        {
            StorageMode = "s3",
            Endpoint = "https://minio.example:9000",
            Region = "us-east-1",
            Bucket = "vaults",
            Prefix = "team/a", // no trailing slash
            AccessKey = "AKIAEXAMPLE",
            LocalVaultPath = "",
            AutoReconnect = true,
            PathStyle = true,
        };

        var json = s.Serialize();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal("s3", root.GetProperty("storageMode").GetString());
        Assert.Equal("https://minio.example:9000", root.GetProperty("endpoint").GetString());
        Assert.Equal("us-east-1", root.GetProperty("region").GetString());
        Assert.Equal("vaults", root.GetProperty("bucket").GetString());
        Assert.Equal("team/a/", root.GetProperty("prefix").GetString());
        Assert.Equal("AKIAEXAMPLE", root.GetProperty("accessKey").GetString());
        Assert.True(root.GetProperty("autoReconnect").GetBoolean());
        Assert.True(root.GetProperty("pathStyle").GetBoolean());
        Assert.False(json.Contains("password", StringComparison.OrdinalIgnoreCase)
            && json.Contains("secret", StringComparison.OrdinalIgnoreCase)
            && json.Contains("CRYPTOMAKO"));

        var back = VaultSettings.Deserialize(json);
        Assert.Equal("team/a/", back.NormalizedPrefix);
        Assert.True(back.PathStyle);
        Assert.False(back.IsLocal);
    }

    [Fact]
    public void AppPreferences_clamps_workers_and_round_trips()
    {
        var p = new AppPreferences
        {
            ProxyMode = "custom",
            ProxyHost = "proxy.example",
            ProxyPort = 3128,
            ProxyUsername = "u",
            BackupTransferMode = AppPreferences.BackupTransferModeSync,
            LimitSyncUploadBandwidth = true,
            SyncUploadCapMbps = 0.5, // below min
            SyncSmallPutConcurrency = 999,
            SyncMediumPutConcurrency = 0,
            SyncLargePutConcurrency = 100,
        };
        var json = p.Serialize();
        Assert.Contains("\"backupTransferMode\"", json);
        Assert.Contains("\"sync\"", json);
        var back = AppPreferences.Deserialize(json);
        Assert.Equal(1, back.SyncUploadCapMbps);
        Assert.Equal(256, back.SyncSmallPutConcurrency);
        Assert.Equal(1, back.SyncMediumPutConcurrency);
        Assert.Equal(16, back.SyncLargePutConcurrency);
        Assert.Equal(AppPreferences.BackupTransferModeSync, back.BackupTransferMode);
        Assert.True(back.IsSyncTransferMode);
    }

    [Fact]
    public void AppPreferences_backupTransferMode_defaults_and_normalizes()
    {
        Assert.Equal(AppPreferences.BackupTransferModeBackup, new AppPreferences().BackupTransferMode);
        Assert.False(new AppPreferences().IsSyncTransferMode);
        Assert.Equal(AppPreferences.BackupTransferModeBackup, AppPreferences.NormalizeBackupTransferMode(""));
        Assert.Equal(AppPreferences.BackupTransferModeBackup, AppPreferences.NormalizeBackupTransferMode("weird"));
        Assert.Equal(AppPreferences.BackupTransferModeSync, AppPreferences.NormalizeBackupTransferMode("SYNC"));
        var missing = AppPreferences.Deserialize("{\"proxyMode\":\"direct\"}");
        Assert.Equal(AppPreferences.BackupTransferModeBackup, missing.BackupTransferMode);
        var invalid = AppPreferences.Deserialize("{\"backupTransferMode\":\"nope\"}");
        Assert.Equal(AppPreferences.BackupTransferModeBackup, invalid.BackupTransferMode);
        var sync = AppPreferences.Deserialize("{\"backupTransferMode\":\"sync\"}");
        Assert.True(sync.IsSyncTransferMode);
    }

    [Fact]
    public void BackupSyncExcludes_locked_keys()
    {
        var e = new BackupSyncExcludes();
        Assert.True(e.ShouldSkipDirectory("node_modules"));
        Assert.True(e.ShouldSkipFile(".DS_Store"));
        Assert.True(e.ShouldSkipFile("x.pyc"));
        var json = e.Serialize();
        using var doc = JsonDocument.Parse(json);
        Assert.True(doc.RootElement.TryGetProperty("directoryNames", out _));
        Assert.True(doc.RootElement.TryGetProperty("fileNames", out _));
        Assert.True(doc.RootElement.TryGetProperty("fileExtensions", out _));
    }
}
