using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

/// <summary>Backup Sync path filters. Platforms-locked: directoryNames, fileNames, fileExtensions.</summary>
public sealed class BackupSyncExcludes
{
    [JsonPropertyName("directoryNames")]
    public HashSet<string> DirectoryNames { get; set; } = new(DefaultDirectoryNames, StringComparer.Ordinal);

    [JsonPropertyName("fileNames")]
    public HashSet<string> FileNames { get; set; } = new(DefaultFileNames, StringComparer.Ordinal);

    [JsonPropertyName("fileExtensions")]
    public HashSet<string> FileExtensions { get; set; } = new(DefaultFileExtensions, StringComparer.OrdinalIgnoreCase);

    public static readonly string[] DefaultDirectoryNames =
    [
        "node_modules", ".git", "__pycache__", ".svn", ".hg", ".tox", ".venv", "venv", ".idea", ".next", "Pods",
    ];

    public static readonly string[] DefaultFileNames = [".DS_Store", "Thumbs.db", "desktop.ini"];

    public static readonly string[] DefaultFileExtensions = ["pyc", "pyo"];

    public bool ShouldSkipDirectory(string name) => DirectoryNames.Contains(name);

    public bool ShouldSkipFile(string name)
    {
        if (FileNames.Contains(name)) return true;
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || dot == name.Length - 1) return false;
        return FileExtensions.Contains(name[(dot + 1)..]);
    }

    /// <summary>True when any path component is an excluded directory or the leaf is an excluded file.</summary>
    public bool ShouldSkipRelativePath(string relativePath)
    {
        var parts = relativePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length; i++)
        {
            var part = parts[i];
            if (DirectoryNames.Contains(part)) return true;
            if (i == parts.Length - 1 && ShouldSkipFile(part)) return true;
        }
        return false;
    }

    public static BackupSyncExcludes Deserialize(string json) =>
        JsonSerializer.Deserialize<BackupSyncExcludes>(json, VaultSettings.JsonOptions) ?? new BackupSyncExcludes();

    public string Serialize() => JsonSerializer.Serialize(this, VaultSettings.JsonOptions);
}
