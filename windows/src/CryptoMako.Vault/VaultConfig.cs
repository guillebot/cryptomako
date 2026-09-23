namespace CryptoMako.Vault;

/// <summary>Non-secret connection settings. Never store password or secret key here.</summary>
public sealed class VaultConfig
{
    public string? Endpoint { get; init; }
    public string? Region { get; init; }
    public string? Bucket { get; init; }
    /// <summary>Object prefix of the vault folder (contains vault.cryptomator).</summary>
    public string? Prefix { get; init; }
    public string? AccessKey { get; init; }
    /// <summary>Local vault directory for --local development.</summary>
    public string? LocalPath { get; init; }
}
