using System.Text;
using Xunit;

namespace CryptoMako.Vault.Tests;

/// <summary>Delete / rename against a copied local vault (DirectoryObjectStore).</summary>
public sealed class VaultMutationTests
{
    private static string RepoRoot =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));

    private static string FixtureVault => Path.Combine(RepoRoot, "fixtures", "vault");

    private static string Password
    {
        get
        {
            var path = Path.Combine(RepoRoot, "fixtures", "PASSWORD");
            Assert.True(File.Exists(path), $"missing password fixture at {path}");
            return File.ReadAllText(path).TrimEnd('\n', '\r');
        }
    }

    private static string CopyVault()
    {
        var dst = Path.Combine(Path.GetTempPath(), "cryptomako-mut-" + Guid.NewGuid().ToString("N"));
        CopyTree(FixtureVault, dst);
        return dst;
    }

    private static void CopyTree(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var dir in Directory.GetDirectories(src, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dir.Replace(src, dst));
        foreach (var file in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
        {
            var target = file.Replace(src, dst);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: true);
        }
    }

    [Fact]
    public async Task Put_DeleteFile_RemovesFromListing()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            await session.PutFileAsync("", "mut-del.txt", Encoding.UTF8.GetBytes("bye\n"));
            Assert.Contains("mut-del.txt", await session.ListFileNamesAsync(""));

            await session.DeleteFileAsync("/mut-del.txt");
            Assert.DoesNotContain("mut-del.txt", await session.ListFileNamesAsync(""));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task Create_DeleteDirectory_EmptyAndRecursive()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            var dir = await session.CreateDirectoryAsync("", "mut-dir");
            await session.PutFileAsync(dir.DirId!, "child.txt", Encoding.UTF8.GetBytes("x"));

            await Assert.ThrowsAsync<InvalidOperationException>(
                () => session.DeleteDirectoryAsync(dir, recursive: false));

            await session.DeleteAsync("/mut-dir", recursive: true);
            var entries = await session.ListAsync("/", recursive: false);
            Assert.DoesNotContain(entries, e => e.Contains("mut-dir"));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task Rename_File_And_Directory_KeepsContents()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            await session.PutFileAsync("", "old-name.txt", Encoding.UTF8.GetBytes("payload\n"));
            await session.RenameAsync("/old-name.txt", "/new-name.txt");
            var names = await session.ListFileNamesAsync("");
            Assert.DoesNotContain("old-name.txt", names);
            Assert.Contains("new-name.txt", names);
            Assert.Equal("payload\n", Encoding.UTF8.GetString(await session.CatAsync("/new-name.txt")));

            var dir = await session.CreateDirectoryAsync("", "dir-a");
            await session.PutFileAsync(dir.DirId!, "inside.txt", Encoding.UTF8.GetBytes("in\n"));
            await session.RenameAsync("/dir-a", "/dir-b");
            var entries = await session.ListAsync("/", recursive: true);
            Assert.DoesNotContain(entries, e => e.Contains("dir-a"));
            Assert.Contains(entries, e => e.Contains("dir-b"));
            Assert.Equal("in\n", Encoding.UTF8.GetString(await session.CatAsync("/dir-b/inside.txt")));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }
}
