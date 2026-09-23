using System.Text;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class VaultGoldenTests
{
    private static string RepoRoot =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static string FixtureVault => Path.Combine(RepoRoot, "fixtures", "vault");

    private static string Password
    {
        get
        {
            // Prefer fixtures/PASSWORD so a developer shell CRYPTOMAKO_PASSWORD
            // cannot poison unlock against the golden vault.
            var path = Path.Combine(RepoRoot, "fixtures", "PASSWORD");
            Assert.True(File.Exists(path), $"missing password fixture at {path}");
            return File.ReadAllText(path).TrimEnd('\n', '\r');
        }
    }

    [Fact]
    public void UnlockLocal_fixture_succeeds()
    {
        Assert.True(Directory.Exists(FixtureVault), $"missing fixture vault at {FixtureVault}");
        using var session = VaultSession.UnlockLocal(FixtureVault, Password);
        Assert.Equal(8, session.Metadata.Format);
        Assert.Equal("SIV_GCM", session.Metadata.CipherCombo);
        Assert.Equal(220, session.Metadata.ShorteningThreshold);
    }

    [Fact]
    public void UnlockLocal_wrong_password_fails()
    {
        Assert.True(Directory.Exists(FixtureVault));
        Assert.ThrowsAny<Exception>(() => VaultSession.UnlockLocal(FixtureVault, "definitely-wrong-password"));
    }

    [Fact]
    public async Task ListAsync_recursive_matches_expected_ls()
    {
        var expectedPath = Path.Combine(RepoRoot, "fixtures", "expected-ls.txt");
        Assert.True(File.Exists(expectedPath));
        var expected = File.ReadAllText(expectedPath).Replace("\r\n", "\n").TrimEnd('\n') + "\n";

        await using var session = VaultSession.UnlockLocal(FixtureVault, Password);
        var entries = await session.ListAsync("/", recursive: true);
        var actual = string.Join("\n", entries) + "\n";
        Assert.Equal(expected, actual);
    }

    [Fact]
    public async Task CatAsync_hello_txt_matches_fixture()
    {
        await using var session = VaultSession.UnlockLocal(FixtureVault, Password);
        var bytes = await session.CatAsync("/hello.txt");
        Assert.Equal(Encoding.UTF8.GetBytes("hello cryptomako\n"), bytes);
    }
}
