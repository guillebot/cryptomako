using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

/// <summary>Non-secret connection settings (Platforms-locked key names). Never store secrets here.</summary>
public sealed class VaultSettings
{
    [JsonPropertyName("storageMode")]
    public string StorageMode { get; set; } = "s3"; // local | s3

    [JsonPropertyName("endpoint")]
    public string Endpoint { get; set; } = "";

    [JsonPropertyName("region")]
    public string Region { get; set; } = "us-east-1";

    [JsonPropertyName("bucket")]
    public string Bucket { get; set; } = "";

    [JsonPropertyName("prefix")]
    public string Prefix { get; set; } = "";

    [JsonPropertyName("accessKey")]
    public string AccessKey { get; set; } = "";

    [JsonPropertyName("localVaultPath")]
    public string LocalVaultPath { get; set; } = "";

    [JsonPropertyName("autoReconnect")]
    public bool AutoReconnect { get; set; }

    /// <summary>True = path-style (MinIO default); false = virtual-hosted.</summary>
    [JsonPropertyName("pathStyle")]
    public bool PathStyle { get; set; } = true;

    [JsonIgnore]
    public bool IsLocal => string.Equals(StorageMode, "local", StringComparison.OrdinalIgnoreCase);

    [JsonIgnore]
    public string NormalizedPrefix
    {
        get
        {
            var trimmed = Prefix.Trim();
            if (trimmed.Length == 0) return "";
            return trimmed.EndsWith('/') ? trimmed : trimmed + "/";
        }
    }

    public void NormalizeForSave()
    {
        Prefix = NormalizedPrefix;
        if (!string.Equals(StorageMode, "local", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(StorageMode, "s3", StringComparison.OrdinalIgnoreCase))
            StorageMode = "s3";
    }

    public static VaultSettings LoadFromFile(string path)
    {
        var json = File.ReadAllText(path);
        return Deserialize(json);
    }

    public static VaultSettings Deserialize(string json)
    {
        var settings = JsonSerializer.Deserialize<VaultSettings>(json, JsonOptions)
            ?? new VaultSettings();
        // Legacy: empty storageMode + localVaultPath => local
        if (string.IsNullOrWhiteSpace(settings.StorageMode))
            settings.StorageMode = string.IsNullOrEmpty(settings.LocalVaultPath) ? "s3" : "local";
        return settings;
    }

    public string Serialize()
    {
        var copy = Clone();
        copy.NormalizeForSave();
        // Omit empty localVaultPath like macOS encode
        return JsonSerializer.Serialize(copy, JsonOptions);
    }

    public void SaveToFile(string path)
    {
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        File.WriteAllText(path, Serialize());
    }

    public VaultSettings Clone() => new()
    {
        StorageMode = StorageMode,
        Endpoint = Endpoint,
        Region = Region,
        Bucket = Bucket,
        Prefix = Prefix,
        AccessKey = AccessKey,
        LocalVaultPath = LocalVaultPath,
        AutoReconnect = AutoReconnect,
        PathStyle = PathStyle,
    };

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };
}
