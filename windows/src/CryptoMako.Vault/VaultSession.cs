using System.Text;

namespace CryptoMako.Vault;

/// <summary>
/// Unlocked Cryptomator format-8 vault session (local filesystem).
/// </summary>
public sealed class VaultSession : IAsyncDisposable, IDisposable
{
    public VaultMetadata Metadata { get; }
    public string RootPath { get; }

    private readonly Masterkey _masterkey;
    private readonly Cryptor _cryptor;
    private VaultSession(VaultMetadata metadata, string rootPath, Masterkey masterkey, Cryptor cryptor)
    {
        Metadata = metadata;
        RootPath = rootPath;
        _masterkey = masterkey;
        _cryptor = cryptor;
    }

    public static VaultSession UnlockLocal(string vaultDirectory, string password)
    {
        if (string.IsNullOrEmpty(password))
            throw new ArgumentException("Password required (CRYPTOMAKO_PASSWORD).", nameof(password));

        var dir = Path.GetFullPath(vaultDirectory);
        if (!Directory.Exists(dir))
            throw new DirectoryNotFoundException(dir);

        var masterKeyPath = Path.Combine(dir, "masterkey.cryptomator");
        if (!File.Exists(masterKeyPath))
            throw new FileNotFoundException("masterkey.cryptomator not found", masterKeyPath);

        var vaultJwtPath = Path.Combine(dir, "vault.cryptomator");
        if (!File.Exists(vaultJwtPath))
            throw new FileNotFoundException("vault.cryptomator not found", vaultJwtPath);

        var masterFile = MasterkeyFile.Load(masterKeyPath);
        var masterkey = masterFile.Unlock(password);

        var jwt = File.ReadAllText(vaultJwtPath).Trim();
        VaultJwt.Payload payload;
        try
        {
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
        return new VaultSession(metadata, dir, masterkey, cryptor);
    }

    public Task<IReadOnlyList<string>> ListAsync(string cleartextPath = "/", bool recursive = false, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var startPath = Normalize(cleartextPath);
        var startDirId = ResolveDirId(startPath);

        if (!recursive)
        {
            var nodes = ListDir(startDirId);
            var names = nodes.Select(n =>
                n.Kind == NodeKind.Directory ? n.CleartextName + "/" :
                n.Kind == NodeKind.Symlink ? n.CleartextName + " ->" :
                n.CleartextName).ToList();
            return Task.FromResult<IReadOnlyList<string>>(names);
        }

        var results = new List<string>();
        var stack = new Stack<(string DirId, string Path, List<VaultNode> Nodes, int Index)>();
        var rootNodes = ListDir(startDirId);
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
            var suffix = node.Kind == NodeKind.Directory ? "/" : "";
            results.Add(childPath + suffix);

            if (node.Kind == NodeKind.Directory && node.DirId is not null)
            {
                var childNodes = ListDir(node.DirId);
                stack.Push((node.DirId, childPath, childNodes, 0));
            }
        }

        return Task.FromResult<IReadOnlyList<string>>(results);
    }

    public Task<byte[]> CatAsync(string cleartextPath, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var node = Resolve(cleartextPath);
        if (node.Kind != NodeKind.File)
            throw new InvalidOperationException($"not a file: {cleartextPath}");

        var ciphertext = File.ReadAllBytes(node.CiphertextPath);
        var clear = _cryptor.DecryptContent(ciphertext);
        return Task.FromResult(clear);
    }

    private List<VaultNode> ListDir(string dirId)
    {
        var dirPath = DirLayout.CiphertextDirectoryPath(RootPath, _cryptor, dirId);
        var nodes = new List<VaultNode>();
        if (!Directory.Exists(dirPath))
            return nodes;

        var dirIdBytes = Encoding.UTF8.GetBytes(dirId);

        foreach (var entry in Directory.EnumerateFileSystemEntries(dirPath))
        {
            var name = Path.GetFileName(entry);
            if (string.IsNullOrEmpty(name) || name == "dirid.c9r")
                continue;

            if (File.Exists(entry) && name.EndsWith(".c9r", StringComparison.Ordinal))
            {
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
                    CiphertextPath = entry,
                });
            }
            else if (Directory.Exists(entry) && name.EndsWith(".c9s", StringComparison.Ordinal))
            {
                var node = TryShortened(entry, name, dirId, dirIdBytes);
                if (node is not null) nodes.Add(node);
            }
            else if (Directory.Exists(entry) && name.EndsWith(".c9r", StringComparison.Ordinal))
            {
                var bare = name[..^4];
                string clear;
                try { clear = _cryptor.DecryptFileName(bare, dirIdBytes); }
                catch { continue; }

                var dirMarker = Path.Combine(entry, "dir.c9r");
                if (File.Exists(dirMarker))
                {
                    var childId = File.ReadAllText(dirMarker).Trim();
                    nodes.Add(new VaultNode
                    {
                        CleartextName = clear,
                        Kind = NodeKind.Directory,
                        CipherName = name,
                        ParentDirId = dirId,
                        DirId = childId,
                        CiphertextPath = dirMarker,
                    });
                }
                else if (File.Exists(Path.Combine(entry, "symlink.c9r")))
                {
                    nodes.Add(new VaultNode
                    {
                        CleartextName = clear,
                        Kind = NodeKind.Symlink,
                        CipherName = name,
                        ParentDirId = dirId,
                        CiphertextPath = Path.Combine(entry, "symlink.c9r"),
                    });
                }
            }
        }

        nodes.Sort((a, b) => string.Compare(a.CleartextName, b.CleartextName, StringComparison.Ordinal));
        return nodes;
    }

    private VaultNode? TryShortened(string folderPath, string cipherName, string parentDirId, byte[] dirIdBytes)
    {
        var namePath = Path.Combine(folderPath, "name.c9s");
        if (!File.Exists(namePath))
            return null;

        var longName = File.ReadAllText(namePath).Trim();
        var bare = longName.EndsWith(".c9r", StringComparison.Ordinal) ? longName[..^4] : longName;
        string clear;
        try { clear = _cryptor.DecryptFileName(bare, dirIdBytes); }
        catch { return null; }

        var dirMarker = Path.Combine(folderPath, "dir.c9r");
        if (File.Exists(dirMarker))
        {
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.Directory,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                DirId = File.ReadAllText(dirMarker).Trim(),
                CiphertextPath = dirMarker,
            };
        }

        var contents = Path.Combine(folderPath, "contents.c9r");
        if (File.Exists(contents))
        {
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.File,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                CiphertextPath = contents,
            };
        }

        var symlink = Path.Combine(folderPath, "symlink.c9r");
        if (File.Exists(symlink))
        {
            return new VaultNode
            {
                CleartextName = clear,
                Kind = NodeKind.Symlink,
                CipherName = cipherName,
                ParentDirId = parentDirId,
                CiphertextPath = symlink,
            };
        }

        return null;
    }

    private string ResolveDirId(string cleartextPath)
    {
        if (cleartextPath == "/")
            return "";

        var parts = Split(cleartextPath);
        var dirId = "";
        for (var i = 0; i < parts.Count; i++)
        {
            var nodes = ListDir(dirId);
            var match = nodes.FirstOrDefault(n => n.CleartextName == parts[i]);
            if (match is null)
                throw new DirectoryNotFoundException(cleartextPath);
            var last = i == parts.Count - 1;
            if (last)
            {
                if (match.Kind != NodeKind.Directory || match.DirId is null)
                    throw new InvalidOperationException($"not a directory: {cleartextPath}");
                return match.DirId;
            }
            if (match.Kind != NodeKind.Directory || match.DirId is null)
                throw new DirectoryNotFoundException(cleartextPath);
            dirId = match.DirId;
        }
        throw new DirectoryNotFoundException(cleartextPath);
    }

    private VaultNode Resolve(string cleartextPath)
    {
        var parts = Split(cleartextPath);
        if (parts.Count == 0)
            throw new FileNotFoundException("path not found", cleartextPath);

        var dirId = "";
        for (var i = 0; i < parts.Count; i++)
        {
            var nodes = ListDir(dirId);
            var match = nodes.FirstOrDefault(n => n.CleartextName == parts[i]);
            if (match is null)
                throw new FileNotFoundException("path not found", cleartextPath);
            var last = i == parts.Count - 1;
            if (last)
                return match;
            if (match.Kind != NodeKind.Directory || match.DirId is null)
                throw new FileNotFoundException("path not found", cleartextPath);
            dirId = match.DirId;
        }
        throw new FileNotFoundException("path not found", cleartextPath);
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

    public void Dispose()
    {
        _cryptor.Dispose();
        _masterkey.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
