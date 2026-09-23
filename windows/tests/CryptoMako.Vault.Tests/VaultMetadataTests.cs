using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class VaultMetadataTests
{
    private static string FixtureVault =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "fixtures", "vault"));

    [Fact]
    public void ReadLocal_fixture_is_format_8()
    {
        Assert.True(Directory.Exists(FixtureVault), $"missing fixture vault at {FixtureVault}");
        var meta = VaultMetadata.ReadLocal(FixtureVault);
        Assert.Equal(8, meta.Format);
        Assert.False(string.IsNullOrWhiteSpace(meta.CipherCombo));
    }
}
