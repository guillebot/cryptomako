using CryptoMako.CfApi;
using Xunit;

namespace CryptoMako.Vault.Tests;

public sealed class CfApiFetchPlaceholdersTests
{
    private static string RepoRoot =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static string FixtureVault => Path.Combine(RepoRoot, "fixtures", "vault");

    private static string Password =>
        File.ReadAllText(Path.Combine(RepoRoot, "fixtures", "PASSWORD")).TrimEnd('\n', '\r');

    [Theory]
    [InlineData("hello.txt", null, true)]
    [InlineData("hello.txt", "*", true)]
    [InlineData("hello.txt", "hello*", true)]
    [InlineData("hello.txt", "*.txt", true)]
    [InlineData("hello.txt", "notes*", false)]
    [InlineData("notes", "notes", true)]
    public void MatchesFetchPattern_Globs(string name, string? pattern, bool expected) =>
        Assert.Equal(expected, CloudFilesProvider.MatchesFetchPattern(name, pattern));

    [Fact]
    public void BuildImmediateChildPlaceholders_OneLevel_Only()
    {
        var children = CloudFilesProvider.BuildImmediateChildPlaceholders("/", new[]
        {
            "hello.txt",
            "bin/",
            "skip ->",
            "nested/should-ignore",
        });
        Assert.Equal(2, children.Count);
        Assert.Contains(children, c => !c.IsDirectory && c.CleartextRelativePath == "hello.txt");
        Assert.Contains(children, c => c.IsDirectory && c.CleartextRelativePath == "bin");
    }

    [Fact]
    public void BuildImmediateChildPlaceholders_UnderParent_JoinsPath()
    {
        var children = CloudFilesProvider.BuildImmediateChildPlaceholders("/notes", new[] { "a.txt", "sub/" });
        Assert.Contains(children, c => c.CleartextRelativePath == "notes/a.txt");
        Assert.Contains(children, c => c.IsDirectory && c.CleartextRelativePath == "notes/sub");
    }

    [Fact]
    public async Task TryListImmediatePlaceholders_FixtureRoot_NoDeepChildren()
    {
        Assert.True(Directory.Exists(FixtureVault));
        await using var session = VaultSession.UnlockLocal(FixtureVault, Password);
        var kids = CloudFilesProvider.TryListImmediatePlaceholders(session, "/");
        Assert.NotEmpty(kids);
        // One level only: relative paths have no slash (nested dirs appear as dir placeholders).
        Assert.DoesNotContain(kids, c => c.CleartextRelativePath.Contains('/'));
    }

    [Fact]
    public void TryListImmediatePlaceholders_NullSession_Empty()
    {
        Assert.Empty(CloudFilesProvider.TryListImmediatePlaceholders(null, "/"));
    }

    [Theory]
    [InlineData("/hello.txt", true)]
    [InlineData("hello.txt", true)]
    [InlineData("/", true)]
    [InlineData("CryptoMako!S-1-5-21!default", false)]
    [InlineData("CryptoMako!SID!account", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void LooksLikeVaultCleartextIdentity_SyncRootIdRejected(string? id, bool expected) =>
        Assert.Equal(expected, CloudFilesProvider.LooksLikeVaultCleartextIdentity(id));
}
