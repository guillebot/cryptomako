using System.Text;

namespace CryptoMako.Vault;

public sealed partial class VaultSession
{
    /// <summary>Creates a directory. Durable only after remote put of dir.c9r (+ name.c9s) and dirid.c9r.</summary>
    public async Task<VaultNode> CreateDirectoryAsync(
        string parentDirId,
        string cleartextName,
        bool skipExistsCheck = false,
        CancellationToken ct = default)
    {
        var name = cleartextName.Trim();
        if (string.IsNullOrEmpty(name) || name.Contains('/'))
            throw new ArgumentException("invalid directory name", nameof(cleartextName));

        if (!skipExistsCheck)
        {
            var existing = await ListDirAsync(parentDirId, ct);
            if (existing.Any(n => n.CleartextName == name))
                throw new InvalidOperationException($"already exists: {name}");
        }

        var childDirId = Guid.NewGuid().ToString().ToUpperInvariant();
        var prepared = WithCryptor(cryptor =>
        {
            var encName = cryptor.EncryptFileName(name, Encoding.UTF8.GetBytes(parentDirId)) + ".c9r";
            var parentPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, cryptor, parentDirId);
            var shortened = encName.Length > Metadata.ShorteningThreshold;
            var display = shortened ? DirLayout.ShortenedName(encName) : encName;
            var folderPrefix = parentPrefix + display + "/";
            var dirMarkerKey = folderPrefix + "dir.c9r";
            var childPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, cryptor, childDirId);
            var dirIdKey = childPrefix + "dirid.c9r";
            return (encName, folderPrefix, dirMarkerKey, dirIdKey, display, shortened);
        });

        var idData = Encoding.UTF8.GetBytes(childDirId);
        if (prepared.shortened)
            await _store.PutObjectAsync(prepared.folderPrefix + "name.c9s", Encoding.UTF8.GetBytes(prepared.encName), ct);
        await _store.PutObjectAsync(prepared.dirMarkerKey, idData, ct);
        await _store.PutObjectAsync(prepared.dirIdKey, idData, ct);

        return new VaultNode
        {
            CleartextName = name,
            Kind = NodeKind.Directory,
            CipherName = prepared.display,
            ParentDirId = parentDirId,
            DirId = childDirId,
            CiphertextKey = prepared.dirMarkerKey,
        };
    }

    /// <summary>Encrypts and uploads a cleartext file. Durable only after remote put 2xx.</summary>
    public async Task<VaultNode> PutFileAsync(
        string parentDirId,
        string cleartextName,
        byte[] cleartextContents,
        CancellationToken ct = default)
    {
        var name = cleartextName.Trim();
        if (string.IsNullOrEmpty(name) || name.Contains('/'))
            throw new ArgumentException("invalid file name", nameof(cleartextName));

        var prepared = WithCryptor(cryptor =>
        {
            var encName = cryptor.EncryptFileName(name, Encoding.UTF8.GetBytes(parentDirId)) + ".c9r";
            var parentPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, cryptor, parentDirId);
            return (encName, parentPrefix);
        });

        byte[] ciphertext;
        using (var worker = MakeWorkerCryptor())
            ciphertext = worker.EncryptContent(cleartextContents);

        string ciphertextKey;
        string displayCipherName;
        if (prepared.encName.Length > Metadata.ShorteningThreshold)
        {
            var shortName = DirLayout.ShortenedName(prepared.encName);
            var folder = prepared.parentPrefix + shortName + "/";
            ciphertextKey = folder + "contents.c9r";
            displayCipherName = shortName;
            await _store.PutObjectAsync(folder + "name.c9s", Encoding.UTF8.GetBytes(prepared.encName), ct);
            await _store.PutObjectAsync(ciphertextKey, ciphertext, ct);
        }
        else
        {
            ciphertextKey = prepared.parentPrefix + prepared.encName;
            displayCipherName = prepared.encName;
            await _store.PutObjectAsync(ciphertextKey, ciphertext, ct);
        }

        return new VaultNode
        {
            CleartextName = name,
            Kind = NodeKind.File,
            CipherName = displayCipherName,
            ParentDirId = parentDirId,
            CiphertextKey = ciphertextKey,
            Size = ciphertext.Length,
        };
    }

    public async Task<VaultNode> PutFileAsync(
        string parentDirId,
        string cleartextName,
        string cleartextFilePath,
        CancellationToken ct = default)
    {
        var bytes = await File.ReadAllBytesAsync(cleartextFilePath, ct);
        return await PutFileAsync(parentDirId, cleartextName, bytes, ct);
    }

    /// <summary>
    /// Encrypts and puts cleartext at a vault path (e.g. /notes/a.txt).
    /// Creates parent dirs as needed. Durable only after remote put 2xx.
    /// Overwrites existing ciphertext object for the same cleartext name.
    /// </summary>
    public async Task<VaultNode> PutAtCleartextPathAsync(string cleartextPath, byte[] cleartextContents, CancellationToken ct = default)
    {
        var norm = NormalizePath(cleartextPath);
        var parts = norm.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
            throw new ArgumentException("put destination must include a file name", nameof(cleartextPath));
        var fileName = parts[^1];
        var parentPath = parts.Length == 1 ? "/" : "/" + string.Join('/', parts.Take(parts.Length - 1));
        var parentDirId = parentPath == "/"
            ? ""
            : await EnsureDirectoryPathAsync(parentPath, ct);
        return await PutFileAsync(parentDirId, fileName, cleartextContents, ct);
    }

    /// <summary>Ensures /a/b/c exists; returns leaf dirId.</summary>
    public async Task<string> EnsureDirectoryPathAsync(string cleartextPath, CancellationToken ct = default)
    {
        var parts = cleartextPath.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Where(p => p is not "." and not "..")
            .ToList();
        var parentDirId = "";
        foreach (var part in parts)
        {
            var kids = await ListDirAsync(parentDirId, ct);
            var existing = kids.FirstOrDefault(n => n.Kind == NodeKind.Directory && n.CleartextName == part);
            if (existing?.DirId is string id)
            {
                parentDirId = id;
                continue;
            }
            var created = await CreateDirectoryAsync(parentDirId, part, skipExistsCheck: true, ct);
            parentDirId = created.DirId ?? throw new InvalidOperationException($"not a directory: {part}");
        }
        return parentDirId;
    }

    public async Task<HashSet<string>> ListFileNamesAsync(string dirId = "", CancellationToken ct = default)
    {
        var nodes = await ListDirAsync(dirId, ct);
        return nodes.Where(n => n.Kind == NodeKind.File).Select(n => n.CleartextName).ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>Deletes a file. Durable only after remote delete succeeds.</summary>
    public async Task DeleteFileAsync(VaultNode node, CancellationToken ct = default)
    {
        if (node.Kind != NodeKind.File)
            throw new InvalidOperationException($"not a file: {node.CleartextName}");

        if (node.CipherName.EndsWith(".c9s", StringComparison.Ordinal))
        {
            var folder = node.CiphertextKey.EndsWith("contents.c9r", StringComparison.Ordinal)
                ? node.CiphertextKey[..^"contents.c9r".Length]
                : node.CiphertextKey.TrimEnd('/') + "/";
            try { await _store.DeleteObjectAsync(folder + "name.c9s", ct); }
            catch (ObjectNotFoundException) { /* ignore companion */ }
            await _store.DeleteObjectAsync(node.CiphertextKey, ct);
        }
        else
        {
            await _store.DeleteObjectAsync(node.CiphertextKey, ct);
        }
    }

    public async Task DeleteFileAsync(string cleartextPath, CancellationToken ct = default)
    {
        var node = await ResolveAsync(cleartextPath, ct);
        if (node.Kind != NodeKind.File)
            throw new InvalidOperationException($"not a file: {cleartextPath}");
        await DeleteFileAsync(node, ct);
    }

    /// <summary>
    /// Deletes a directory marker. Refuses non-empty dirs unless <paramref name="recursive"/>.
    /// Fail-closed: each remote delete must succeed (except optional companions).
    /// </summary>
    public async Task DeleteDirectoryAsync(VaultNode node, bool recursive = false, CancellationToken ct = default)
    {
        if (node.Kind != NodeKind.Directory || node.DirId is null)
            throw new InvalidOperationException($"not a directory: {node.CleartextName}");

        var children = await ListDirAsync(node.DirId, ct);
        if (children.Count > 0)
        {
            if (!recursive)
                throw new InvalidOperationException($"directory not empty: {node.CleartextName}");

            foreach (var child in children.Where(c => c.Kind is NodeKind.File or NodeKind.Symlink))
                await DeleteFileAsync(child, ct);
            foreach (var child in children.Where(c => c.Kind == NodeKind.Directory))
                await DeleteDirectoryAsync(child, recursive: true, ct);
        }

        if (!string.IsNullOrEmpty(node.CiphertextKey))
        {
            await _store.DeleteObjectAsync(node.CiphertextKey, ct);
            if (node.CipherName.EndsWith(".c9s", StringComparison.Ordinal))
            {
                var folder = node.CiphertextKey.EndsWith("dir.c9r", StringComparison.Ordinal)
                    ? node.CiphertextKey[..^"dir.c9r".Length]
                    : node.CiphertextKey.TrimEnd('/') + "/";
                try { await _store.DeleteObjectAsync(folder + "name.c9s", ct); }
                catch (ObjectNotFoundException) { }
            }
        }

        var childPrefix = WithCryptor(c => DirLayout.CiphertextDirectoryPrefix(Prefix, c, node.DirId));
        try { await _store.DeleteObjectAsync(childPrefix + "dirid.c9r", ct); }
        catch (ObjectNotFoundException) { }
    }

    public async Task DeleteAsync(string cleartextPath, bool recursive = false, CancellationToken ct = default)
    {
        var node = await ResolveAsync(cleartextPath, ct);
        switch (node.Kind)
        {
            case NodeKind.Directory:
                await DeleteDirectoryAsync(node, recursive, ct);
                break;
            case NodeKind.File:
            case NodeKind.Symlink:
                await DeleteFileAsync(node, ct);
                break;
            default:
                throw new InvalidOperationException($"unsupported node kind: {node.Kind}");
        }
    }

    /// <summary>
    /// Renames a file or directory within the vault (same or new parent path).
    /// Directories keep their dirId (children ciphertext paths stay valid).
    /// Fail-closed: new object put must succeed before old delete.
    /// </summary>
    public async Task<VaultNode> RenameAsync(string fromCleartextPath, string toCleartextPath, CancellationToken ct = default)
    {
        var from = NormalizePath(fromCleartextPath);
        var to = NormalizePath(toCleartextPath);
        if (from == to)
            return await ResolveAsync(from, ct);

        var node = await ResolveAsync(from, ct);
        var toParts = to.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (toParts.Count == 0)
            throw new ArgumentException("invalid destination path", nameof(toCleartextPath));

        var newName = toParts[^1];
        var parentPath = toParts.Count == 1 ? "/" : "/" + string.Join('/', toParts.Take(toParts.Count - 1));
        var parentDirId = parentPath == "/"
            ? ""
            : await ResolveDirIdAsync(parentPath, ct);

        // Collision check
        var siblings = await ListDirAsync(parentDirId, ct);
        if (siblings.Any(s => s.CleartextName == newName))
            throw new InvalidOperationException($"already exists: {to}");

        if (node.Kind == NodeKind.File)
        {
            var cipherBytes = await _store.GetObjectAsync(node.CiphertextKey, ct);
            var created = await PutCiphertextFileAsync(parentDirId, newName, cipherBytes, ct);
            await DeleteFileAsync(node, ct);
            return created;
        }

        if (node.Kind == NodeKind.Directory && node.DirId is not null)
        {
            // Re-link same dirId under a new encrypted name; children stay put.
            var created = await CreateDirectoryLinkAsync(parentDirId, newName, node.DirId, ct);
            // Remove old parent marker only (keep dirid.c9r under the dirId prefix).
            if (!string.IsNullOrEmpty(node.CiphertextKey))
            {
                await _store.DeleteObjectAsync(node.CiphertextKey, ct);
                if (node.CipherName.EndsWith(".c9s", StringComparison.Ordinal))
                {
                    var folder = node.CiphertextKey.EndsWith("dir.c9r", StringComparison.Ordinal)
                        ? node.CiphertextKey[..^"dir.c9r".Length]
                        : node.CiphertextKey.TrimEnd('/') + "/";
                    try { await _store.DeleteObjectAsync(folder + "name.c9s", ct); }
                    catch (ObjectNotFoundException) { }
                }
            }
            return created;
        }

        throw new InvalidOperationException($"cannot rename: {from}");
    }

    private async Task<VaultNode> PutCiphertextFileAsync(
        string parentDirId,
        string cleartextName,
        byte[] ciphertext,
        CancellationToken ct)
    {
        var name = cleartextName.Trim();
        var prepared = WithCryptor(cryptor =>
        {
            var encName = cryptor.EncryptFileName(name, Encoding.UTF8.GetBytes(parentDirId)) + ".c9r";
            var parentPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, cryptor, parentDirId);
            return (encName, parentPrefix);
        });

        string ciphertextKey;
        string display;
        if (prepared.encName.Length > Metadata.ShorteningThreshold)
        {
            display = DirLayout.ShortenedName(prepared.encName);
            var folder = prepared.parentPrefix + display + "/";
            ciphertextKey = folder + "contents.c9r";
            await _store.PutObjectAsync(folder + "name.c9s", Encoding.UTF8.GetBytes(prepared.encName), ct);
            await _store.PutObjectAsync(ciphertextKey, ciphertext, ct);
        }
        else
        {
            display = prepared.encName;
            ciphertextKey = prepared.parentPrefix + prepared.encName;
            await _store.PutObjectAsync(ciphertextKey, ciphertext, ct);
        }

        return new VaultNode
        {
            CleartextName = name,
            Kind = NodeKind.File,
            CipherName = display,
            ParentDirId = parentDirId,
            CiphertextKey = ciphertextKey,
            Size = ciphertext.Length,
        };
    }

    /// <summary>Creates a directory entry pointing at an existing dirId (used by rename).</summary>
    private async Task<VaultNode> CreateDirectoryLinkAsync(
        string parentDirId,
        string cleartextName,
        string childDirId,
        CancellationToken ct)
    {
        var name = cleartextName.Trim();
        var prepared = WithCryptor(cryptor =>
        {
            var encName = cryptor.EncryptFileName(name, Encoding.UTF8.GetBytes(parentDirId)) + ".c9r";
            var parentPrefix = DirLayout.CiphertextDirectoryPrefix(Prefix, cryptor, parentDirId);
            var shortened = encName.Length > Metadata.ShorteningThreshold;
            var display = shortened ? DirLayout.ShortenedName(encName) : encName;
            var folderPrefix = parentPrefix + display + "/";
            var dirMarkerKey = folderPrefix + "dir.c9r";
            return (encName, folderPrefix, dirMarkerKey, display, shortened);
        });

        var idData = Encoding.UTF8.GetBytes(childDirId);
        if (prepared.shortened)
            await _store.PutObjectAsync(prepared.folderPrefix + "name.c9s", Encoding.UTF8.GetBytes(prepared.encName), ct);
        await _store.PutObjectAsync(prepared.dirMarkerKey, idData, ct);

        return new VaultNode
        {
            CleartextName = name,
            Kind = NodeKind.Directory,
            CipherName = prepared.display,
            ParentDirId = parentDirId,
            DirId = childDirId,
            CiphertextKey = prepared.dirMarkerKey,
        };
    }

    private static string NormalizePath(string path)
    {
        if (string.IsNullOrEmpty(path) || path == "/") return "/";
        var p = path.StartsWith('/') ? path : "/" + path;
        if (p.Length > 1 && p.EndsWith('/')) p = p.TrimEnd('/');
        return p;
    }
}
