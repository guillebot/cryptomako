namespace CryptoMako.Vault;

public enum NodeKind
{
    File,
    Directory,
    Symlink,
}

public sealed class VaultNode
{
    public required string CleartextName { get; init; }
    public required NodeKind Kind { get; init; }
    public required string CipherName { get; init; }
    public required string ParentDirId { get; init; }
    public string? DirId { get; init; }
    /// <summary>Object key (or local store key) for ciphertext payload.</summary>
    public required string CiphertextKey { get; init; }
    public long? Size { get; init; }
    public string? ETag { get; init; }
}
