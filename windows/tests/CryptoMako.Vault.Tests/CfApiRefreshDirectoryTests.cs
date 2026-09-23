using CryptoMako.CfApi;
using Xunit;

namespace CryptoMako.Vault.Tests;

public sealed class CfApiRefreshDirectoryTests
{
    private static string RepoRoot =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static string FixtureVault => Path.Combine(RepoRoot, "fixtures", "vault");

    private static string Password =>
        File.ReadAllText(Path.Combine(RepoRoot, "fixtures", "PASSWORD")).TrimEnd('\n', '\r');

    [Fact]
    public void TryEnableOnDemandPopulation_MissingPath_ReturnsFalse()
    {
        var missing = Path.Combine(Path.GetTempPath(), "cm-missing-dir-" + Guid.NewGuid().ToString("N"));
        Assert.False(CloudFilesProvider.TryEnableOnDemandPopulation(missing));
    }

    [Fact]
    public void TryVaultPathToFsPath_MapsUnderSyncRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-map-" + Guid.NewGuid().ToString("N"));
        using var provider = new CloudFilesProvider(root);
        Assert.Equal(Path.GetFullPath(root), provider.TryVaultPathToFsPath("/"));
        var nested = provider.TryVaultPathToFsPath("/notes/a");
        Assert.NotNull(nested);
        Assert.EndsWith(Path.Combine("notes", "a"), nested!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RefreshDirectoryAsync_SeedsImmediateChildren_OnWindows()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return;
        Assert.True(Directory.Exists(FixtureVault));

        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CryptoMako",
            "cfapi-refresh-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        await using var session = VaultSession.UnlockLocal(FixtureVault, Password);
        using var provider = new CloudFilesProvider(root);
        try
        {
            provider.RegisterSyncRoot("refresh-smoke");
            provider.Connect();
            provider.AttachSession(session);

            var n = await provider.RefreshDirectoryAsync("/");
            Assert.True(n >= 1);
            // Root listing should include at least one known fixture name as placeholder file/dir.
            var entries = Directory.EnumerateFileSystemEntries(root).Select(Path.GetFileName).ToHashSet(StringComparer.OrdinalIgnoreCase);
            Assert.True(entries.Count >= 1);
        }
        finally
        {
            try { provider.Disconnect(); } catch { }
            try { if (provider.GetStatus().Registered) provider.UnregisterSyncRoot(); } catch { }
            try { Directory.Delete(root, true); } catch { }
        }
    }
}
