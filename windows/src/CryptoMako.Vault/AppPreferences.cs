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

    public static AppPreferences Deserialize(string json) =>
        JsonSerializer.Deserialize<AppPreferences>(json, VaultSettings.JsonOptions) ?? new AppPreferences();

    public string Serialize()
    {
        var copy = new AppPreferences
        {
            ProxyMode = ProxyMode,
            ProxyHost = ProxyHost,
            ProxyPort = ProxyPort,
            ProxyUsername = ProxyUsername,
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
