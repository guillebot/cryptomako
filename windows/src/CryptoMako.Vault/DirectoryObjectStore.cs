namespace CryptoMako.Vault;

/// <summary>Filesystem-backed store for --local and golden fixtures.</summary>
public sealed class DirectoryObjectStore : IObjectStore
{
    public string Root { get; }

    public DirectoryObjectStore(string root)
    {
        Root = Path.GetFullPath(root);
        if (!Directory.Exists(Root))
            throw new DirectoryNotFoundException(Root);
    }

    public Task<byte[]> GetObjectAsync(string key, CancellationToken ct = default)
    {
        var path = Resolve(key);
        if (!File.Exists(path))
            throw new ObjectNotFoundException(key);
        return File.ReadAllBytesAsync(path, ct);
    }

    public async Task GetObjectAsync(string key, string destinationPath, CancellationToken ct = default)
    {
        var source = Resolve(key);
        if (!File.Exists(source))
            throw new ObjectNotFoundException(key);
        var dir = Path.GetDirectoryName(destinationPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        await using var src = File.OpenRead(source);
        await using var dst = File.Create(destinationPath);
        await src.CopyToAsync(dst, ct);
    }

    public Task<ListedObject> HeadObjectAsync(string key, CancellationToken ct = default)
    {
        var path = Resolve(key);
        if (!File.Exists(path))
            throw new ObjectNotFoundException(key);
        var info = new FileInfo(path);
        // Include mtime so remote-change probes can detect local vault.cryptomator edits.
        var etag = $"local-{info.Length}-{info.LastWriteTimeUtc.Ticks}";
        return Task.FromResult(new ListedObject { Key = key, Size = info.Length, ETag = etag });
    }

    public Task<PrefixListing> ListImmediateAsync(string prefix, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var relative = prefix.TrimEnd('/');
        var dir = string.IsNullOrEmpty(relative) ? Root : Resolve(relative);
        var listing = new PrefixListing();
        if (!Directory.Exists(dir))
            return Task.FromResult(listing);

        var keyPrefix = string.IsNullOrEmpty(prefix) ? ""
            : prefix.EndsWith('/') ? prefix : prefix + "/";

        foreach (var entry in Directory.EnumerateFileSystemEntries(dir))
        {
            var name = Path.GetFileName(entry);
            if (Directory.Exists(entry))
                listing.CommonPrefixes.Add(keyPrefix + name + "/");
            else if (File.Exists(entry))
            {
                var info = new FileInfo(entry);
                listing.Objects.Add(new ListedObject
                {
                    Key = keyPrefix + name,
                    Size = info.Length,
                    ETag = "local",
                });
            }
        }
        return Task.FromResult(listing);
    }

    public async Task PutObjectAsync(string key, byte[] data, CancellationToken ct = default)
    {
        var path = Resolve(key);
        var parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent))
            Directory.CreateDirectory(parent);
        await File.WriteAllBytesAsync(path, data, ct);
    }

    public async Task PutObjectAsync(string key, string sourceFilePath, CancellationToken ct = default)
    {
        var data = await File.ReadAllBytesAsync(sourceFilePath, ct);
        await PutObjectAsync(key, data, ct);
    }

    public Task DeleteObjectAsync(string key, CancellationToken ct = default)
    {
        var path = Resolve(key);
        if (!File.Exists(path))
            throw new ObjectNotFoundException(key);
        File.Delete(path);
        return Task.CompletedTask;
    }

    private string Resolve(string key)
    {
        if (key.Contains("..", StringComparison.Ordinal) || key.StartsWith('/'))
            throw new ObjectStoreException("invalid object key");
        if (string.IsNullOrEmpty(key))
            return Root;
        var candidate = Path.GetFullPath(Path.Combine(Root, key.Replace('/', Path.DirectorySeparatorChar)));
        var rootFull = Root.EndsWith(Path.DirectorySeparatorChar)
            ? Root
            : Root + Path.DirectorySeparatorChar;
        if (!candidate.Equals(Root, StringComparison.OrdinalIgnoreCase)
            && !candidate.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
            throw new ObjectStoreException("invalid object key");
        // Reject symlink / junction escape outside the vault root (macOS SafePath).
        AssertInsideRoot(candidate);
        return candidate;
    }

    private void AssertInsideRoot(string candidate)
    {
        var rootReal = EvalPath(Root);
        var rootPrefix = rootReal.EndsWith(Path.DirectorySeparatorChar)
            ? rootReal
            : rootReal + Path.DirectorySeparatorChar;

        string rel;
        try
        {
            rel = Path.GetRelativePath(Root, candidate);
        }
        catch (ArgumentException)
        {
            throw new ObjectStoreException("invalid object key");
        }
        if (rel == ".." || rel.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || rel.StartsWith("../", StringComparison.Ordinal))
            throw new ObjectStoreException("invalid object key");

        // Walk each segment, resolving reparse points so a symlink under the vault
        // cannot point a key at a path outside Root (macOS SafePath parity).
        var cur = rootReal;
        foreach (var part in rel.Replace('/', Path.DirectorySeparatorChar)
                     .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == "." || part == "..")
                throw new ObjectStoreException("invalid object key");
            var next = Path.Combine(cur, part);
            cur = (Directory.Exists(next) || File.Exists(next))
                ? EvalPath(next)
                : Path.GetFullPath(next);
            if (!cur.Equals(rootReal, StringComparison.OrdinalIgnoreCase)
                && !cur.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                throw new ObjectStoreException("invalid object key");
        }
    }

    private static string EvalPath(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                var target = Directory.ResolveLinkTarget(path, returnFinalTarget: true);
                if (target is not null)
                    return Path.GetFullPath(target.FullName);
            }
            else if (File.Exists(path))
            {
                var target = File.ResolveLinkTarget(path, returnFinalTarget: true);
                if (target is not null)
                    return Path.GetFullPath(target.FullName);
            }
        }
        catch (IOException)
        {
            // Fall through.
        }
        return Path.GetFullPath(path);
    }
}
