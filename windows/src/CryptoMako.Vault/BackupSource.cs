using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

/// <summary>
/// One local cleartext folder synced into <c>Backups/{vaultFolderName}/</c>.
/// Windows-local JSON (<c>backup-sources.json</c>) — mirrors the Mac mental model
/// (<c>id</c> / <c>path</c> / <c>vaultFolderName</c>); not part of settings.json until Platforms Settings.
/// </summary>
public sealed class BackupSource
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("D");

    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    /// <summary>Cleartext folder name under <c>Backups/</c> in the vault (Mac field name).</summary>
    [JsonPropertyName("vaultFolderName")]
    public string VaultFolderName { get; set; } = "";

    [JsonPropertyName("addedAt")]
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.UtcNow;

    public static BackupSource Create(string path, string? vaultFolderName = null)
    {
        var full = System.IO.Path.GetFullPath(path);
        var name = vaultFolderName?.Trim();
        if (string.IsNullOrEmpty(name))
            name = new DirectoryInfo(full).Name;
        if (string.IsNullOrEmpty(name))
            name = "Backup";
        return new BackupSource
        {
            Id = Guid.NewGuid().ToString("D"),
            Path = full,
            VaultFolderName = name,
            AddedAt = DateTimeOffset.UtcNow,
        };
    }
}

/// <summary>Persists backup sources outside settings.json (Windows AppData / Mac host ~/.config).</summary>
public sealed class BackupSourcesStore
{
    [JsonPropertyName("sources")]
    public List<BackupSource> Sources { get; set; } = new();

    public static BackupSourcesStore Empty { get; } = new();

    public static BackupSourcesStore LoadFromFile(string path)
    {
        if (!File.Exists(path)) return new BackupSourcesStore();
        try
        {
            return JsonSerializer.Deserialize<BackupSourcesStore>(File.ReadAllText(path), VaultSettings.JsonOptions)
                   ?? new BackupSourcesStore();
        }
        catch
        {
            return new BackupSourcesStore();
        }
    }

    public void SaveToFile(string path)
    {
        var dir = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        File.WriteAllText(path, JsonSerializer.Serialize(this, VaultSettings.JsonOptions));
    }
}

/// <summary>
/// Nested / overlapping Backup Sync sources (Platforms consensus):
/// soft-warn on add; hard-fail on Sync start when one resolved path prefixes another.
/// </summary>
public static class BackupPathOverlap
{
    public sealed record OverlapPair(BackupSource A, BackupSource B, string ResolvedA, string ResolvedB);

    /// <summary>Resolve to a comparable absolute path (full path + final symlink target when available).</summary>
    public static string Resolve(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("path required", nameof(path));

        var full = System.IO.Path.GetFullPath(path.Trim());
        try
        {
            // Prefer final symlink / junction target when the OS can resolve it.
            if (Directory.Exists(full))
            {
                var target = Directory.ResolveLinkTarget(full, returnFinalTarget: true);
                if (target is not null)
                    full = System.IO.Path.GetFullPath(target.FullName);
            }
            else if (File.Exists(full))
            {
                var target = File.ResolveLinkTarget(full, returnFinalTarget: true);
                if (target is not null)
                    full = System.IO.Path.GetFullPath(target.FullName);
            }
        }
        catch
        {
            // Best-effort: fall back to GetFullPath.
        }

        return TrimSep(full);
    }

    public static bool IsSameOrPrefix(string ancestor, string descendant)
    {
        var a = TrimSep(ancestor);
        var b = TrimSep(descendant);
        if (string.Equals(a, b, PathComparer))
            return true;
        var prefix = a + System.IO.Path.DirectorySeparatorChar;
        return b.StartsWith(prefix, PathComparer);
    }

    public static IReadOnlyList<OverlapPair> FindOverlaps(IEnumerable<BackupSource> sources)
    {
        var list = sources.ToList();
        var resolved = new List<(BackupSource Src, string Path)>();
        foreach (var s in list)
        {
            if (string.IsNullOrWhiteSpace(s.Path)) continue;
            try { resolved.Add((s, Resolve(s.Path))); }
            catch { /* skip unresolvable for soft paths; Sync will fail separately */ }
        }

        var pairs = new List<OverlapPair>();
        for (var i = 0; i < resolved.Count; i++)
        {
            for (var j = i + 1; j < resolved.Count; j++)
            {
                var (sa, pa) = resolved[i];
                var (sb, pb) = resolved[j];
                if (IsSameOrPrefix(pa, pb) || IsSameOrPrefix(pb, pa))
                    pairs.Add(new OverlapPair(sa, sb, pa, pb));
            }
        }
        return pairs;
    }

    /// <summary>Human soft-warn when adding <paramref name="candidatePath"/> beside existing sources.</summary>
    public static string? SoftWarnOnAdd(IEnumerable<BackupSource> existing, string candidatePath)
    {
        BackupSource candidate;
        try { candidate = BackupSource.Create(candidatePath); }
        catch { return null; }

        var overlaps = FindOverlaps(existing.Append(candidate));
        if (overlaps.Count == 0) return null;

        var o = overlaps[0];
        return $"Warning: backup source overlaps another (nested paths). " +
               $"'{o.ResolvedA}' ↔ '{o.ResolvedB}'. Sync will refuse to start until resolved.";
    }

    /// <summary>Hard-fail before Sync when any pair overlaps.</summary>
    public static void ThrowIfOverlapping(IEnumerable<BackupSource> sources)
    {
        var overlaps = FindOverlaps(sources);
        if (overlaps.Count == 0) return;
        var o = overlaps[0];
        throw new InvalidOperationException(
            $"Backup Sync refused: nested/overlapping sources. " +
            $"'{o.ResolvedA}' overlaps '{o.ResolvedB}'. Remove or change one source before syncing.");
    }

    private static string TrimSep(string p) =>
        p.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);

    private static StringComparison PathComparer =>
        OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
}
