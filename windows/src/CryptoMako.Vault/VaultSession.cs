namespace CryptoMako.Vault;

/// <summary>
/// Unlocked vault session. Decrypt/list/cat require Cryptomator format-8 crypto
/// (cryptolib-java or equivalent). Until Platforms golden crypto is wired,
/// <see cref="ListAsync"/> / <see cref="CatAsync"/> throw with a clear boundary.
/// Metadata unlock via <see cref="VaultMetadata"/> always works for format checks.
/// </summary>
public sealed class VaultSession : IAsyncDisposable, IDisposable
{
    public VaultMetadata Metadata { get; }
    public string RootPath { get; }

    private VaultSession(VaultMetadata metadata, string rootPath)
    {
        Metadata = metadata;
        RootPath = rootPath;
    }

    public static VaultSession UnlockLocal(string vaultDirectory, string password)
    {
        if (string.IsNullOrEmpty(password))
            throw new ArgumentException("Password required (CRYPTOMAKO_PASSWORD).", nameof(password));

        var dir = Path.GetFullPath(vaultDirectory);
        if (!Directory.Exists(dir))
            throw new DirectoryNotFoundException(dir);

        var meta = VaultMetadata.ReadLocal(dir);

        var masterKey = Path.Combine(dir, "masterkey.cryptomator");
        if (!File.Exists(masterKey))
            throw new FileNotFoundException("masterkey.cryptomator not found", masterKey);

        _ = password; // accepted at boundary; full verify with cryptolib later
        return new VaultSession(meta, dir);
    }

    public Task<IReadOnlyList<string>> ListAsync(string cleartextPath = "/", bool recursive = false, CancellationToken ct = default)
    {
        throw new NotImplementedException(
            "Format-8 directory listing needs Cryptomator crypto (cryptolib). " +
            "Golden acceptance: match fixtures/expected-ls.txt. Tracked for Platforms crypto wire-up.");
    }

    public Task<byte[]> CatAsync(string cleartextPath, CancellationToken ct = default)
    {
        throw new NotImplementedException(
            "Format-8 content decrypt needs Cryptomator crypto (cryptolib). " +
            "Golden acceptance: cat /hello.txt equals fixture bytes.");
    }

    public void Dispose() { }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
