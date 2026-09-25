
namespace CryptoMako.Vault;

/// <summary>
/// Pure helpers for smb:// Backup Sync sources (no WNet / no CredMan).
/// Mirrors macOS CryptoMakoShared.SMBSourceURL.
/// </summary>
public static class SMBSourceURL
{
    public sealed class ParseException : Exception
    {
        public ParseException(string message) : base(message) { }
    }

    /// <summary>Normalize user input into canonical smb://host/share[/path] (no credentials in URL).</summary>
    public static string Normalize(string raw)
    {
        var trimmed = (raw ?? "").Trim();
        if (trimmed.Length == 0)
            throw new ParseException("SMB URL is empty.");

        var working = trimmed;
        if (working.StartsWith(@"\\", StringComparison.Ordinal) || working.StartsWith("//", StringComparison.Ordinal))
        {
            var unc = working.TrimStart('\\', '/');
            var parts = unc.Split(new[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2)
                throw new ParseException("SMB URL must include a share name (smb://server/share).");
            working = "smb://" + string.Join("/", parts);
        }

        if (!Uri.TryCreate(working, UriKind.Absolute, out var uri)
            || !string.Equals(uri.Scheme, "smb", StringComparison.OrdinalIgnoreCase))
        {
            throw new ParseException(
                "SMB URL must start with smb:// (example: smb://server/share or smb://server/share/path).");
        }

        if (string.IsNullOrEmpty(uri.Host))
            throw new ParseException("SMB URL is missing a server host.");

        var pathParts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (pathParts.Length == 0 || string.IsNullOrEmpty(pathParts[0]))
            throw new ParseException("SMB URL must include a share name (smb://server/share).");

        var share = pathParts[0];
        var remainder = pathParts.Skip(1).ToArray();
        var normalized = "smb://" + uri.Host;
        if (!uri.IsDefaultPort && uri.Port > 0)
            normalized += ":" + uri.Port;
        normalized += "/" + share;
        if (remainder.Length > 0)
            normalized += "/" + string.Join("/", remainder);
        return normalized;
    }

    /// <summary>Durable UNC \\host\share[\subpath] from a normalized smb:// URL.</summary>
    public static string ToUnc(string normalizedSmbUrl)
    {
        var n = Normalize(normalizedSmbUrl);
        if (!Uri.TryCreate(n, UriKind.Absolute, out var uri))
            throw new ParseException("Invalid SMB URL after normalize.");
        var pathParts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (pathParts.Length == 0)
            throw new ParseException("SMB URL must include a share name (smb://server/share).");
        var host = uri.Host;
        // Port is not part of UNC; Windows SMB uses 445. Keep host only.
        return @"\\" + host + @"\" + string.Join(@"\", pathParts);
    }

    /// <summary>\\host\share only (connection root for WNetAddConnection2).</summary>
    public static string ToShareUnc(string normalizedSmbUrl)
    {
        var n = Normalize(normalizedSmbUrl);
        if (!Uri.TryCreate(n, UriKind.Absolute, out var uri))
            throw new ParseException("Invalid SMB URL after normalize.");
        var pathParts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (pathParts.Length == 0)
            throw new ParseException("SMB URL must include a share name (smb://server/share).");
        return @"\\" + uri.Host + @"\" + pathParts[0];
    }

    public static string SuggestedVaultFolderName(string? smbUrl, string path)
    {
        if (!string.IsNullOrWhiteSpace(smbUrl))
        {
            try
            {
                var share = ShareName(Normalize(smbUrl));
                if (!string.IsNullOrEmpty(share))
                    return share;
            }
            catch
            {
                // fall through
            }
        }

        var leaf = Path.GetFileName(path.TrimEnd('\\', '/'));
        return string.IsNullOrEmpty(leaf) ? "SMB" : leaf;
    }

    public static string? ShareName(string normalizedSmbUrl)
    {
        try
        {
            var n = Normalize(normalizedSmbUrl);
            if (!Uri.TryCreate(n, UriKind.Absolute, out var uri))
                return null;
            return uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        }
        catch
        {
            return null;
        }
    }

    public static string ShortLabel(string normalizedSmbUrl)
    {
        try
        {
            var n = Normalize(normalizedSmbUrl);
            if (!Uri.TryCreate(n, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
                return normalizedSmbUrl;
            var share = ShareName(n) ?? "";
            return string.IsNullOrEmpty(share) ? uri.Host : uri.Host + "/" + share;
        }
        catch
        {
            return normalizedSmbUrl;
        }
    }
}
