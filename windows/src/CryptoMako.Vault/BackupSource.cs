using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

/// <summary>
/// One local cleartext folder (or SMB mount) synced into <c>Backups/{vaultFolderName}/</c>.
/// Windows-local JSON (<c>backup-sources.json</c>) — mirrors the Mac mental model
/// (<c>id</c> / <c>path</c> / <c>vaultFolderName</c> / <c>kind</c> / <c>smbURL</c>);
/// not part of settings.json until Platforms Settings. Password never stored in JSON.
/// </summary>
public sealed class BackupSource
{
    public const string KindFolder = "folder";
    public const string KindSmb = "smb";

    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString("D");

    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    /// <summary>Cleartext folder name under <c>Backups/</c> in the vault (Mac field name).</summary>
    [JsonPropertyName("vaultFolderName")]
    public string VaultFolderName { get; set; } = "";

    [JsonPropertyName("addedAt")]
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary><c>folder</c> (default, legacy) or <c>smb</c>. Missing JSON field migrates to folder.</summary>
    [JsonPropertyName("kind")]
    public string Kind { get; set; } = KindFolder;

    /// <summary>Canonical <c>smb://server/share[/path]</c> when Kind is smb. Never includes password.</summary>
    [JsonPropertyName("smbURL")]
    public string? SmbURL { get; set; }

    /// <summary>Optional SMB username (password lives in Credential Manager only).</summary>
    [JsonPropertyName("smbUsername")]
    public string? SmbUsername { get; set; }

    [JsonIgnore]
    public bool IsSMB =>
        string.Equals(Kind, KindSmb, StringComparison.OrdinalIgnoreCase)
        || (!string.IsNullOrWhiteSpace(SmbURL));

    /// <summary>Secondary line in the Backup list (smb:// URL or local path).</summary>
    [JsonIgnore]
    public string DisplayLocation =>
        IsSMB && !string.IsNullOrWhiteSpace(SmbURL) ? SmbURL! : Path;

    /// <summary>Credential Manager account for this source SMB password (never JSON).</summary>
    [JsonIgnore]
    public string SmbPasswordAccount => "smb-password-" + Id;

    public static BackupSource Create(string path, string? vaultFolderName = null)
    {
        var full = System.IO.Path.GetFullPath(path);
        var name = ComposeVaultFolderName(vaultFolderName, full);
        return new BackupSource
        {
            Id = Guid.NewGuid().ToString("D"),
            Path = full,
            VaultFolderName = name,
            AddedAt = DateTimeOffset.UtcNow,
            Kind = KindFolder,
        };
    }

    /// <summary>Create an SMB source. Password is NOT stored on the object — caller saves to CredMan.</summary>
    public static BackupSource CreateSmb(
        string smbUrl,
        string mountedUncPath,
        string? username = null,
        string? vaultFolderName = null)
    {
        var normalized = SMBSourceURL.Normalize(smbUrl);
        var unc = string.IsNullOrWhiteSpace(mountedUncPath)
            ? SMBSourceURL.ToUnc(normalized)
            : mountedUncPath;
        var sharePrefix = SMBSourceURL.SuggestedVaultFolderName(normalized, unc);
        var name = ComposeVaultFolderName(vaultFolderName, sharePrefix, isSmbShareName: true);
        return new BackupSource
        {
            Id = Guid.NewGuid().ToString("D"),
            Path = unc,
            VaultFolderName = name,
            AddedAt = DateTimeOffset.UtcNow,
            Kind = KindSmb,
            SmbURL = normalized,
            SmbUsername = string.IsNullOrWhiteSpace(username) ? null : username.Trim(),
        };
    }

    /// <summary>
    /// Stable cleartext prefix for one source root under <c>Backups/{vaultFolder}/</c>.
    /// When the source root is exactly the user profile (<c>.../Users/{name}</c>), returns
    /// <c>Users/{name}</c>; UNC/SMB uses the share name; otherwise the last path segment.
    /// </summary>
    public static string SuggestSourcePrefix(string localRoot)
    {
        if (string.IsNullOrWhiteSpace(localRoot))
            return "Backup";

        var trimmed = localRoot.Trim();
        // UNC / already-mounted SMB paths: use share name (second segment) so they don't
        // collide with local profile sources (Users/guill).
        if (trimmed.StartsWith(@"\\", StringComparison.Ordinal) || trimmed.StartsWith("//", StringComparison.Ordinal))
        {
            var unc = trimmed.TrimStart('\\', '/');
            var parts = unc.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2 && !string.IsNullOrEmpty(parts[1]))
                return parts[1];
            if (parts.Length >= 1 && !string.IsNullOrEmpty(parts[0]))
                return parts[0];
        }

        var full = System.IO.Path.GetFullPath(trimmed)
            .TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);
        var pathParts = full.Split(
                new[] { System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar },
                StringSplitOptions.RemoveEmptyEntries)
            .Where(p => p.Length > 0 && !(p.Length == 2 && p[1] == ':')) // drop "C:"
            .ToArray();

        if (pathParts.Length == 0)
            return "Backup";

        // Unambiguous home root only: .../Users/{name} or .../home/{name} with no deeper
        // segments -> "Users/guill". Deeper paths (Documents, Temp, ...) keep the leaf so
        // Temp under the profile does not become a long Users/guill/AppData/... prefix.
        for (var i = 0; i < pathParts.Length - 1; i++)
        {
            if ((pathParts[i].Equals("Users", StringComparison.OrdinalIgnoreCase)
                 || pathParts[i].Equals("home", StringComparison.OrdinalIgnoreCase))
                && i + 1 == pathParts.Length - 1)
            {
                return pathParts[i] + "/" + pathParts[i + 1];
            }
        }

        var leaf = pathParts[^1];
        return string.IsNullOrEmpty(leaf) ? "Backup" : leaf;
    }

    /// <summary>
    /// Compose <c>Backups/{result}/</c> destination folder. When <paramref name="vaultFolderName"/>
    /// is a host/vault label (e.g. hostname <c>MONSTER</c>), nests the source prefix under it
    /// (<c>MONSTER/Users/guill</c> or <c>MONSTER/share</c> for SMB) so multiple sources do not mix.
    /// </summary>
    public static string ComposeVaultFolderName(string? vaultFolderName, string localRoot, bool isSmbShareName = false)
    {
        string prefix;
        if (isSmbShareName)
        {
            prefix = (localRoot ?? "").Trim().Replace('\\', '/').Trim('/');
            if (prefix.Contains('/'))
                prefix = prefix[(prefix.LastIndexOf('/') + 1)..];
            if (string.IsNullOrEmpty(prefix))
                prefix = "SMB";
        }
        else
        {
            prefix = SuggestSourcePrefix(localRoot);
        }
        var name = (vaultFolderName ?? "").Trim().Replace('\\', '/').Trim('/');
        if (string.IsNullOrEmpty(name))
            return prefix;

        var cmp = StringComparison.OrdinalIgnoreCase;
        if (name.Equals(prefix, cmp) || name.EndsWith("/" + prefix, cmp))
            return name;

        var leaf = prefix.Contains('/') ? prefix[(prefix.LastIndexOf('/') + 1)..] : prefix;
        if (!string.IsNullOrEmpty(leaf)
            && (name.Equals(leaf, cmp) || name.EndsWith("/" + leaf, cmp)))
            return name;

        return name + "/" + prefix;
    }

    /// <summary>
    /// Soft-migrate stored sources so vaultFolderName includes the source prefix.
    /// Returns true when any entry changed (caller should persist).
    /// Does not touch vault objects already synced under a bare host folder.
    /// Missing <c>kind</c> on legacy JSON deserializes as folder (default).
    /// </summary>
    public static bool EnsureSourcePrefixedVaultFolders(IEnumerable<BackupSource> sources)
    {
        var changed = false;
        foreach (var s in sources)
        {
            if (string.IsNullOrWhiteSpace(s.Path) && string.IsNullOrWhiteSpace(s.SmbURL)) continue;
            // Soft-normalize kind when smbURL present but kind missing/folder.
            if (!string.IsNullOrWhiteSpace(s.SmbURL)
                && !string.Equals(s.Kind, KindSmb, StringComparison.OrdinalIgnoreCase))
            {
                s.Kind = KindSmb;
                changed = true;
            }
            try
            {
                string composed;
                if (s.IsSMB)
                {
                    var share = SMBSourceURL.SuggestedVaultFolderName(s.SmbURL, s.Path);
                    composed = ComposeVaultFolderName(s.VaultFolderName, share, isSmbShareName: true);
                }
                else
                {
                    composed = ComposeVaultFolderName(s.VaultFolderName, s.Path);
                }
                if (!string.Equals(composed, s.VaultFolderName, StringComparison.Ordinal))
                {
                    s.VaultFolderName = composed;
                    changed = true;
                }
            }
            catch
            {
                // leave unresolvable paths alone
            }
        }
        return changed;
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

        var full = path.Trim();
        // Keep UNC as-is (GetFullPath can mangle \\server\share on some hosts).
        if (!(full.StartsWith(@"\\", StringComparison.Ordinal) || full.StartsWith("//", StringComparison.Ordinal)))
            full = System.IO.Path.GetFullPath(full);
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
            // Best-effort: fall back to GetFullPath / UNC.
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
        try
        {
            if (candidatePath.StartsWith(@"\\", StringComparison.Ordinal)
                || candidatePath.StartsWith("//", StringComparison.Ordinal)
                || candidatePath.StartsWith("smb://", StringComparison.OrdinalIgnoreCase))
            {
                candidate = new BackupSource { Path = candidatePath.Trim(), Kind = BackupSource.KindSmb };
            }
            else
            {
                candidate = BackupSource.Create(candidatePath);
            }
        }
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