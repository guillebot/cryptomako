namespace CryptoMako.Vault;

/// <summary>
/// Relative path under a Backup source root. Fail-closed: never invent a fallback
/// leaf name when the path is not under the root.
/// Mirrors <c>Sources/CryptoMakoShared/BackupRelativePath.swift</c>.
/// </summary>
public static class BackupRelativePath
{
    public sealed class NotUnderRootException : Exception
    {
        public NotUnderRootException(string filePath, string rootPath)
            : base($"Path is not under backup source root: {filePath} (root {rootPath})")
        {
            FilePath = filePath;
            RootPath = rootPath;
        }

        public string FilePath { get; }
        public string RootPath { get; }
    }

    /// <summary>
    /// Slash-separated relative path of <paramref name="filePath"/> under
    /// <paramref name="rootPath"/>. Requires a real path-component boundary.
    /// </summary>
    public static string Make(string filePath, string rootPath)
    {
        var fileFull = Path.GetFullPath(filePath);
        var rootFull = Path.GetFullPath(rootPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.Equals(fileFull, rootFull, StringComparison.OrdinalIgnoreCase))
            return "";

        var rel = Path.GetRelativePath(rootFull, fileFull).Replace('\\', '/');
        if (rel == ".." || rel.StartsWith("../", StringComparison.Ordinal)
            || Path.IsPathRooted(rel))
        {
            throw new NotUnderRootException(fileFull, rootFull);
        }
        return rel;
    }
}
