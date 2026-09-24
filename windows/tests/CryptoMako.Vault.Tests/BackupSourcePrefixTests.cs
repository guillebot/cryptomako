using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupSourcePrefixTests
{
    [Theory]
    [InlineData(@"C:\Users\guill", "Users/guill")]
    [InlineData(@"C:\Users\guill\Documents", "Documents")]
    [InlineData(@"C:\Users\Alice", "Users/Alice")]
    public void SuggestSourcePrefix_users_home_suffix(string path, string expected)
    {
        Assert.Equal(expected, BackupSource.SuggestSourcePrefix(path));
    }

    [Theory]
    [InlineData(@"D:\Projects", "Projects")]
    [InlineData(@"E:\work\MyApp", "MyApp")]
    [InlineData(@"Z:\data", "data")]
    public void SuggestSourcePrefix_non_users_is_leaf(string path, string expected)
    {
        // GetFullPath does not require the drive to exist; avoids Temp under C:\Users\...
        Assert.Equal(expected, BackupSource.SuggestSourcePrefix(path));
    }

    [Fact]
    public void Compose_nests_prefix_under_hostname()
    {
        var composed = BackupSource.ComposeVaultFolderName("MONSTER", @"C:\Users\guill");
        Assert.Equal("MONSTER/Users/guill", composed);
    }

    [Fact]
    public void Compose_idempotent_when_already_prefixed()
    {
        Assert.Equal(
            "MONSTER/Users/guill",
            BackupSource.ComposeVaultFolderName("MONSTER/Users/guill", @"C:\Users\guill"));
    }

    [Fact]
    public void Compose_mac_style_leaf_alone_not_doubled()
    {
        Assert.Equal("guill", BackupSource.ComposeVaultFolderName("guill", @"C:\Users\guill"));
    }

    [Fact]
    public void Compose_null_vault_folder_uses_prefix()
    {
        Assert.Equal("Users/guill", BackupSource.ComposeVaultFolderName(null, @"C:\Users\guill"));
        Assert.Equal("Users/guill", BackupSource.ComposeVaultFolderName("  ", @"C:\Users\guill"));
    }

    [Fact]
    public void Create_with_hostname_composes_prefix()
    {
        var src = BackupSource.Create(@"C:\Users\guill", "MONSTER");
        Assert.Equal("MONSTER/Users/guill", src.VaultFolderName);
        Assert.Equal(Path.GetFullPath(@"C:\Users\guill"), src.Path);
    }

    [Fact]
    public void EnsureSourcePrefixedVaultFolders_rewrites_bare_host()
    {
        var s = new BackupSource
        {
            Path = Path.GetFullPath(@"C:\Users\guill"),
            VaultFolderName = "MONSTER",
        };
        Assert.True(BackupSource.EnsureSourcePrefixedVaultFolders(new[] { s }));
        Assert.Equal("MONSTER/Users/guill", s.VaultFolderName);
        Assert.False(BackupSource.EnsureSourcePrefixedVaultFolders(new[] { s }));
    }
}
