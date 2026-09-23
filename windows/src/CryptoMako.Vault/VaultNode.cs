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
    /// <summary>Absolute filesystem path to ciphertext payload (file contents or dir.c9r).</summary>
    public required string CiphertextPath { get; init; }
}
