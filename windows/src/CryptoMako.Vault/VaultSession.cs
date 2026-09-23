using System.Text;

namespace CryptoMako.Vault;

/// <summary>Unlocked Cryptomator format-8 vault session over an <see cref="IObjectStore"/>.</summary>
public sealed partial class VaultSession : IAsyncDisposable, IDisposable
{
    public VaultMetadata Metadata { get; }
    /// <summary>Local root path when using <see cref="DirectoryObjectStore"/>; otherwise bucket/prefix label.</summary>
    public string RootPath { get; }
    public string Prefix { get; }

    private readonly Masterkey _masterkey;
    private readonly Cryptor _cryptor;
    private readonly IObjectStore _store;
    private readonly object _cryptorLock = new();

    private VaultSession(
        VaultMetadata metadata,
        string rootPath,
        string prefix,
        Masterkey masterkey,
        Cryptor cryptor,
        IObjectStore store)
    {
        Metadata = metadata;
        RootPath = rootPath;
        Prefix = prefix;
        _masterkey = masterkey;
        _cryptor = cryptor;
        _store = store;
    }

    public static VaultSession UnlockLocal(string vaultDirectory, string password)
    {
        var dir = Path.GetFullPath(vaultDirectory);
        var store = new DirectoryObjectStore(dir);
        return UnlockAsync(store, prefix: "", password, rootLabel: dir)
            .GetAwaiter().GetResult();
    }

    public static async Task<VaultSession> UnlockAsync(
        IObjectStore store,
        string prefix,
        string password,
        string? rootLabel = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(password))
            throw new ArgumentException("Password required (CRYPTOMAKO_PASSWORD).", nameof(password));

        var vaultPrefix = NormalizePrefix(prefix);

        byte[] masterData;
        try
        {
            masterData = await store.GetObjectAsync(vaultPrefix + "masterkey.cryptomator", ct);
        }
        catch (ObjectNotFoundException)
        {
            throw new FileNotFoundException("masterkey.cryptomator not found");
        }

        byte[] jwtBytes;
        try
        {
            jwtBytes = await store.GetObjectAsync(vaultPrefix + "vault.cryptomator", ct);
        }
        catch (ObjectNotFoundException)
        {
            throw new FileNotFoundException("vault.cryptomator not found");
        }

        var masterFile = MasterkeyFile.Parse(Encoding.UTF8.GetString(masterData));
        var masterkey = masterFile.Unlock(password);

        VaultJwt.Payload payload;
        try
        {
            var jwt = Encoding.UTF8.GetString(jwtBytes).Trim();
            payload = VaultJwt.Verify(jwt, masterkey.RawKey);
        }
        catch
        {
            masterkey.Dispose();
            throw;
        }

        if (payload.Format != 8)
        {
            masterkey.Dispose();
            throw new NotSupportedException($"Only Cryptomator format 8 is supported (got {payload.Format})");
        }

        if (!string.Equals(payload.CipherCombo, "SIV_GCM", StringComparison.Ordinal))
        {
            masterkey.Dispose();
            throw new NotSupportedException($"Unsupported cipherCombo: {payload.CipherCombo}");
        }

        var shortening = payload.ShorteningThreshold > 0 ? payload.ShorteningThreshold : 220;
        var metadata = new VaultMetadata
        {
            Format = payload.Format,
            CipherCombo = payload.CipherCombo ?? "SIV_GCM",
            ShorteningThreshold = shortening,
            Jti = payload.Jti,
        };

        var cryptor = new Cryptor(masterkey);
        var label = rootLabel ?? (string.IsNullOrEmpty(vaultPrefix) ? "s3" : vaultPrefix.TrimEnd('/'));
        return new VaultSession(metadata, label, vaultPrefix, masterkey, cryptor, store);
    }

    public async Task<IReadOnlyList<string>> ListAsync(
        string cleartextPath = "/",
        bool recursive = false,
        CancellationToken ct = default)
    {
        var startPath = Normalize(cleartextPath);
        var startDirId = await ResolveDirIdAsync(startPath, ct);

        if (!recursive)
        {
            var nodes = await ListDirAsync(startDirId, ct);
            return nodes.Select(n =>
                n.Kind == NodeKind.Directory ? n.CleartextName + "/" :
                n.Kind == NodeKind.Symlink ? n.CleartextName + " ->" :
                n.CleartextName).ToList();
        }

        var results = new List<string>();
        var stack = new Stack<(string DirId, string Path, List<VaultNode> Nodes, int Index)>();
        var rootNodes = await ListDirAsync(startDirId, ct);
        stack.Push((startDirId, startPath, rootNodes, 0));

        while (stack.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var frame = stack.Pop();
            if (frame.Index >= frame.Nodes.Count)
                continue;

            var node = frame.Nodes[frame.Index];
            stack.Push((frame.DirId, frame.Path, frame.Nodes, frame.Index + 1));

            var childPath = frame.Path == "/"
                ? "/" + node.CleartextName
                : frame.Path + "/" + node.CleartextName;
            results.Add(childPath + (node.Kind == NodeKind.Directory ? "/" : ""));

            if (node.Kind == NodeKind.Directory && node.DirId is not null)
            {
                var childNodes = await ListDirAsync(node.DirId, ct);
                stack.Push((node.DirId, childPath, childNodes, 0));
            }
        }

        return results;
    }

    public async Task<byte[]> CatAsync(string cleartextPath, CancellationToken ct = default)
    {
        var node = await ResolveAsync(cleartextPath, ct);
        if (node.Kind != NodeKind.File)
            throw new InvalidOperationException($"not a file: {cleartextPath}");

        var ciphertext = await _store.GetObjectAsync(node.CiphertextKey, ct);
        return _cryptor.DecryptContent(ciphertext);
    }

    public async Task GetAsync(string cleartextPath, string destinationPath, CancellationToken ct = default)
    {
        var bytes = await CatAsync(cleartextPath, ct);
        var dir = Path.GetDirectoryName(destinationPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        await File.WriteAllBytesAsync(destinationPath, bytes, ct);
    }

    public async Task<VaultNode> StatAsync(string cleartextPath, CancellationToken ct = default)
        => await ResolveAsync(cleartextPath, ct);

    private async Task<List<VaultNode>> ListDirAsync(string dirId, CancellationToken ct)
    {
        var dirPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, _cryptor, dirId);
        var listing = await _store.ListImmediateAsync(dirPrefix, ct);
        var nodes = new List<VaultNode>();
        var dirIdBytes = Encoding.UTF8.GetBytes(dirId);

        foreach (var obj in listing.Objects)
        {
            var name = RelativeName(obj.Key, dirPrefix);
            if (string.IsNullOrEmpty(name) || name.Contains('/') || name == "dirid.c9r")
                continue;
            if (!name.EndsWith(".c9r", StringComparison.Ordinal))
                continue;

            var bare = name[..^4];
            string clear;
            try { clear = _cryptor.DecryptFileName(bare, dirIdBytes); }
            catch { continue; }

            nodes.Add(new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.File,
                CipherName = name,
                ParentDirId = dirId,
                CiphertextKey = obj.Key,
                Size = obj.Size,
                ETag = obj.ETag,
            });
        }

        foreach (var common in listing.CommonPrefixes)
        {
            var folderName = RelativeName(common, dirPrefix).TrimEnd('/');
            if (string.IsNullOrEmpty(folderName) || folderName.Contains('/'))
                continue;

            var folderPrefix = common.EndsWith('/') ? common : common + "/";
            if (folderName.EndsWith(".c9s", StringComparison.Ordinal))
            {
                var node = await TryShortenedAsync(folderName, dirId, dirIdBytes, folderPrefix, ct);
                if (node is not null) nodes.Add(node);
            }
            else if (folderName.EndsWith(".c9r", StringComparison.Ordinal))
            {
                var bare = folderName[..^4];
                string clear;
                try { clear = _cryptor.DecryptFileName(bare, dirIdBytes); }
                catch { continue; }

                try
                {
                    var dirBytes = await _store.GetObjectAsync(folderPrefix + "dir.c9r", ct);
                    var childId = Encoding.UTF8.GetString(dirBytes).Trim();
                    nodes.Add(new VaultNode
                    {
                        CleartextName = clear,
                        Kind = NodeKind.Directory,
                        CipherName = folderName,
                        ParentDirId = dirId,
                        DirId = childId,
                        CiphertextKey = folderPrefix + "dir.c9r",
                    });
                }
                catch (ObjectNotFoundException)
                {
                    try
                    {
                        await _store.HeadObjectAsync(folderPrefix + "symlink.c9r", ct);
                        nodes.Add(new VaultNode
                        {
                            CleartextName = clear,
                            Kind = NodeKind.Symlink,
                            CipherName = folderName,
                            ParentDirId = dirId,
                            CiphertextKey = folderPrefix + "symlink.c9r",
                        });
                    }
                    catch (ObjectNotFoundException) { /* skip */ }
                }
            }
        }

        nodes.Sort((a, b) => string.Compare(a.CleartextName, b.CleartextName, StringComparison.Ordinal));
        return nodes;
    }

    private async Task<VaultNode?> TryShortenedAsync(
        string cipherName,
        string parentDirId,
        byte[] dirIdBytes,
        string folderPrefix,
        CancellationToken ct)
    {
        byte[] nameBytes;
        try { nameBytes = await _store.GetObjectAsync(folderPrefix + "name.c9s", ct); }
        catch (ObjectNotFoundException) { return null; }

        var longName = Encoding.UTF8.GetString(nameBytes).Trim();
        var bare = longName.EndsWith(".c9r", StringComparison.Ordinal) ? longName[..^4] : longName;
        string clear;
        try { clear = _cryptor.DecryptFileName(bare, dirIdBytes); }
        catch { return null; }

        try
        {
            var dirBytes = await _store.GetObjectAsync(folderPrefix + "dir.c9r", ct);
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.Directory,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                DirId = Encoding.UTF8.GetString(dirBytes).Trim(),
                CiphertextKey = folderPrefix + "dir.c9r",
            };
        }
        catch (ObjectNotFoundException) { /* fall through */ }

        try
        {
            var head = await _store.HeadObjectAsync(folderPrefix + "contents.c9r", ct);
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.File,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                CiphertextKey = folderPrefix + "contents.c9r",
                Size = head.Size,
                ETag = head.ETag,
            };
        }
        catch (ObjectNotFoundException) { /* fall through */ }

        try
        {
            await _store.HeadObjectAsync(folderPrefix + "symlink.c9r", ct);
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.Symlink,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                CiphertextKey = folderPrefix + "symlink.c9r",
            };
        }
        catch (ObjectNotFoundException)
        {
            return null;
        }
    }

    private async Task<string> ResolveDirIdAsync(string cleartextPath, CancellationToken ct)
    {
        if (cleartextPath == "/")
            return "";

        var parts = Split(cleartextPath);
        var dirId = "";
        for (var i = 0; i < parts.Count; i++)
        {
            var nodes = await ListDirAsync(dirId, ct);
            var match = nodes.FirstOrDefault(n => n.CleartextName == parts[i]);
            if (match is null)
                throw new DirectoryNotFoundException(cleartextPath);
            if (match.Kind != NodeKind.Directory || match.DirId is null)
                throw new InvalidOperationException($"not a directory: {cleartextPath}");
            dirId = match.DirId;
            if (i == parts.Count - 1)
                return dirId;
        }
        throw new DirectoryNotFoundException(cleartextPath);
    }

    private async Task<VaultNode> ResolveAsync(string cleartextPath, CancellationToken ct)
    {
        var parts = Split(cleartextPath);
        if (parts.Count == 0)
            throw new FileNotFoundException("path not found", cleartextPath);

        var dirId = "";
        for (var i = 0; i < parts.Count; i++)
        {
            var nodes = await ListDirAsync(dirId, ct);
            var match = nodes.FirstOrDefault(n => n.CleartextName == parts[i]);
            if (match is null)
                throw new FileNotFoundException("path not found", cleartextPath);
            if (i == parts.Count - 1)
                return match;
            if (match.Kind != NodeKind.Directory || match.DirId is null)
                throw new FileNotFoundException("path not found", cleartextPath);
            dirId = match.DirId;
        }
        throw new FileNotFoundException("path not found", cleartextPath);
    }

    private static string RelativeName(string key, string prefix)
    {
        if (key.StartsWith(prefix, StringComparison.Ordinal))
            return key[prefix.Length..];
        return key;
    }

    public static string NormalizePrefix(string prefix)
    {
        var trimmed = prefix.Trim();
        if (trimmed.Length == 0) return "";
        return trimmed.EndsWith('/') ? trimmed : trimmed + "/";
    }

    private static string Normalize(string path)
    {
        if (string.IsNullOrEmpty(path) || path == "/")
            return "/";
        var p = path.StartsWith('/') ? path : "/" + path;
        if (p.Length > 1 && p.EndsWith('/'))
            p = p.TrimEnd('/');
        return p;
    }

    private static List<string> Split(string path) =>
        Normalize(path).Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();

    internal Cryptor MakeWorkerCryptor() => Cryptor.CreateWorker(_masterkey);

    internal T WithCryptor<T>(Func<Cryptor, T> body)
    {
        lock (_cryptorLock)
            return body(_cryptor);
    }

    public void Dispose()
    {
        _cryptor.Dispose();
        _masterkey.Dispose();
        if (_store is IDisposable d)
            d.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
