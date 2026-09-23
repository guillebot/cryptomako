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
}
