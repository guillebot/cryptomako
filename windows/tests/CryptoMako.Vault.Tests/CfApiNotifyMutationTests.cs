using System.Text;
using CryptoMako.CfApi;
using Xunit;

namespace CryptoMako.Vault.Tests;

/// <summary>
/// CfAPI NOTIFY_DELETE / NOTIFY_RENAME helpers: vault mutation + fail-closed when remote fails.
/// </summary>
public sealed class CfApiNotifyMutationTests
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
        var dst = Path.Combine(Path.GetTempPath(), "cryptomako-cfapi-mut-" + Guid.NewGuid().ToString("N"));
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
    public void MapFsPath_UnderSyncRoot_ReturnsVaultCleartext()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-root-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "notes"));
        try
        {
            var mapped = CloudFilesProvider.TryMapFsPathToVaultCleartext(
                root, Path.Combine(root, "notes", "a.txt"));
            Assert.Equal("/notes/a.txt", mapped);

            Assert.Null(CloudFilesProvider.TryMapFsPathToVaultCleartext(root, root));
            Assert.Null(CloudFilesProvider.TryMapFsPathToVaultCleartext(
                root, Path.Combine(Path.GetTempPath(), "outside.txt")));

            var volRel = root.Substring(2); // drop "C:" → "\Users\..."
            var viaVol = CloudFilesProvider.TryMapFsPathToVaultCleartext(
                root, volRel + "\\hello.txt", volumeDosName: root[..2]);
            Assert.Equal("/hello.txt", viaVol);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void AcknowledgeMutation_FailClosed_WithoutRemoteOk()
    {
        Assert.Throws<InvalidOperationException>(() =>
            CloudFilesProvider.AcknowledgeMutationOnlyIfRemoteOk(false));
        CloudFilesProvider.AcknowledgeMutationOnlyIfRemoteOk(true);
    }

    [Fact]
    public async Task TryDeleteFromVault_Success_RemovesListing()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            await session.PutFileAsync("", "cf-del.txt", Encoding.UTF8.GetBytes("x\n"));
            Assert.True(CloudFilesProvider.TryDeleteFromVault(session, "/cf-del.txt"));
            Assert.DoesNotContain("cf-del.txt", await session.ListFileNamesAsync(""));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task TryDeleteFromVault_RemoteFailure_FailClosed()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            var inner = new DirectoryObjectStore(vaultDir);
            var store = new FailingDeleteStore(inner);
            await using var session = await VaultSession.UnlockAsync(store, prefix: "", Password, rootLabel: vaultDir);
            await session.PutFileAsync("", "cf-fail-del.txt", Encoding.UTF8.GetBytes("y\n"));

            Assert.False(CloudFilesProvider.TryDeleteFromVault(session, "/cf-fail-del.txt"));
            // Re-open with healthy store: object should still be present (delete never succeeded).
            await using var check = VaultSession.UnlockLocal(vaultDir, Password);
            Assert.Contains("cf-fail-del.txt", await check.ListFileNamesAsync(""));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task TryRenameInVault_Success_MovesListing()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            await session.PutFileAsync("", "cf-old.txt", Encoding.UTF8.GetBytes("z\n"));
            Assert.True(CloudFilesProvider.TryRenameInVault(session, "/cf-old.txt", "/cf-new.txt"));
            var names = await session.ListFileNamesAsync("");
            Assert.DoesNotContain("cf-old.txt", names);
            Assert.Contains("cf-new.txt", names);
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task TryRenameInVault_RemoteFailure_FailClosed()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            // Seed with a healthy session first (rename does put-then-delete).
            await using (var seed = VaultSession.UnlockLocal(vaultDir, Password))
                await seed.PutFileAsync("", "cf-ren-old.txt", Encoding.UTF8.GetBytes("keep\n"));

            var store = new FailingPutStore(new DirectoryObjectStore(vaultDir));
            await using var failing = await VaultSession.UnlockAsync(store, prefix: "", Password, rootLabel: vaultDir);
            Assert.False(CloudFilesProvider.TryRenameInVault(failing, "/cf-ren-old.txt", "/cf-ren-new.txt"));

            await using var check = VaultSession.UnlockLocal(vaultDir, Password);
            var names = await check.ListFileNamesAsync("");
            Assert.Contains("cf-ren-old.txt", names);
            Assert.DoesNotContain("cf-ren-new.txt", names);
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void TryDelete_NullSessionOrBadPath_FailClosed()
    {
        Assert.False(CloudFilesProvider.TryDeleteFromVault(null, "/x"));
        Assert.False(CloudFilesProvider.TryRenameInVault(null, "/a", "/b"));
    }

    [Fact]
    public void EncodeFileIdentity_NormalizesPath()
    {
        Assert.Equal("/notes/a.txt", CloudFilesProvider.NormalizeVaultCleartextPath(@"notes\a.txt"));
        Assert.Equal("/notes/a.txt", CloudFilesProvider.NormalizeVaultCleartextPath("/notes/a.txt/"));
        Assert.Equal(
            "/hello.txt",
            System.Text.Encoding.UTF8.GetString(CloudFilesProvider.EncodeFileIdentity("hello.txt")));
    }

    [Fact]
    public void TryUpdatePlaceholderFileIdentity_MissingFile_ReturnsFalse()
    {
        var missing = Path.Combine(Path.GetTempPath(), "cm-missing-" + Guid.NewGuid().ToString("N"), "nope.txt");
        Assert.False(CloudFilesProvider.TryUpdatePlaceholderFileIdentity(missing, "/nope.txt"));
        Assert.Null(CloudFilesProvider.TryReadPlaceholderFileIdentity(missing));
    }

    [Fact]
    public async Task TryWriteBackCleartext_Success_RoundtripsCat()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using var session = VaultSession.UnlockLocal(vaultDir, Password);
            Assert.True(CloudFilesProvider.TryWriteBackCleartext(
                session, "/cf-wb.txt", Encoding.UTF8.GetBytes("written-back\n")));
            Assert.Equal("written-back\n", Encoding.UTF8.GetString(await session.CatAsync("/cf-wb.txt")));
            // overwrite
            Assert.True(CloudFilesProvider.TryWriteBackCleartext(
                session, "/cf-wb.txt", Encoding.UTF8.GetBytes("again\n")));
            Assert.Equal("again\n", Encoding.UTF8.GetString(await session.CatAsync("/cf-wb.txt")));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public async Task TryWriteBackCleartext_RemoteFailure_FailClosed()
    {
        Assert.True(Directory.Exists(FixtureVault));
        var vaultDir = CopyVault();
        try
        {
            await using (var seed = VaultSession.UnlockLocal(vaultDir, Password))
                await seed.PutFileAsync("", "cf-wb-keep.txt", Encoding.UTF8.GetBytes("orig\n"));

            var store = new FailingPutStore(new DirectoryObjectStore(vaultDir));
            await using var failing = await VaultSession.UnlockAsync(store, prefix: "", Password, rootLabel: vaultDir);
            Assert.False(CloudFilesProvider.TryWriteBackCleartext(
                failing, "/cf-wb-keep.txt", Encoding.UTF8.GetBytes("should-not-land\n")));

            await using var check = VaultSession.UnlockLocal(vaultDir, Password);
            Assert.Equal("orig\n", Encoding.UTF8.GetString(await check.CatAsync("/cf-wb-keep.txt")));
        }
        finally
        {
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void TryWriteBack_NullSessionOrBadPath_FailClosed()
    {
        Assert.False(CloudFilesProvider.TryWriteBackCleartext(null, "/x", new byte[] { 1 }));
        Assert.False(CloudFilesProvider.TryWriteBackCleartext(null, "/", new byte[] { 1 }));
    }

    [Fact]
    public void FileIdentity_Update_Roundtrip_OnWindowsPlaceholder()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return;

        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CryptoMako",
            "cfapi-id-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var provider = new CloudFilesProvider(root);
        try
        {
            provider.RegisterSyncRoot("identity-smoke");
            provider.Connect();
            var n = provider.CreatePlaceholders(new[]
            {
                new CloudFilesPlaceholder
                {
                    CleartextRelativePath = "old-name.txt",
                    CiphertextKey = "",
                    IsDirectory = false,
                    FileSize = 4,
                },
            });
            Assert.True(n >= 1);
            var ph = Path.Combine(root, "old-name.txt");
            Assert.True(File.Exists(ph));

            var before = CloudFilesProvider.TryReadPlaceholderFileIdentity(ph);
            Assert.Equal("/old-name.txt", before);

            Assert.True(CloudFilesProvider.TryUpdatePlaceholderFileIdentity(ph, "/new-name.txt"));
            var after = CloudFilesProvider.TryReadPlaceholderFileIdentity(ph);
            Assert.Equal("/new-name.txt", after);
        }
        finally
        {
            try { provider.Disconnect(); } catch { }
            try { if (provider.GetStatus().Registered) provider.UnregisterSyncRoot(); } catch { }
            try { Directory.Delete(root, true); } catch { }
        }
    }

        /// <summary>Delegates all ops except DeleteObjectAsync, which simulates remote non-2xx.</summary>
    private sealed class FailingDeleteStore : IObjectStore
    {
        private readonly IObjectStore _inner;
        public FailingDeleteStore(IObjectStore inner) => _inner = inner;
        public Task<byte[]> GetObjectAsync(string key, CancellationToken ct = default) => _inner.GetObjectAsync(key, ct);
        public Task GetObjectAsync(string key, string destinationPath, CancellationToken ct = default) =>
            _inner.GetObjectAsync(key, destinationPath, ct);
        public Task<ListedObject> HeadObjectAsync(string key, CancellationToken ct = default) =>
            _inner.HeadObjectAsync(key, ct);
        public Task<PrefixListing> ListImmediateAsync(string prefix, CancellationToken ct = default) =>
            _inner.ListImmediateAsync(prefix, ct);
        public Task PutObjectAsync(string key, byte[] data, CancellationToken ct = default) =>
            _inner.PutObjectAsync(key, data, ct);
        public Task PutObjectAsync(string key, string sourceFilePath, CancellationToken ct = default) =>
            _inner.PutObjectAsync(key, sourceFilePath, ct);
        public Task DeleteObjectAsync(string key, CancellationToken ct = default) =>
            Task.FromException(new ObjectStoreException("simulated remote delete failure (non-2xx)"));
    }

    /// <summary>Delegates all ops except PutObjectAsync, which simulates remote put failure on rename.</summary>
    private sealed class FailingPutStore : IObjectStore
    {
        private readonly IObjectStore _inner;
        private int _puts;
        public FailingPutStore(IObjectStore inner) => _inner = inner;
        public Task<byte[]> GetObjectAsync(string key, CancellationToken ct = default) => _inner.GetObjectAsync(key, ct);
        public Task GetObjectAsync(string key, string destinationPath, CancellationToken ct = default) =>
            _inner.GetObjectAsync(key, destinationPath, ct);
        public Task<ListedObject> HeadObjectAsync(string key, CancellationToken ct = default) =>
            _inner.HeadObjectAsync(key, ct);
        public Task<PrefixListing> ListImmediateAsync(string prefix, CancellationToken ct = default) =>
            _inner.ListImmediateAsync(prefix, ct);
        public Task PutObjectAsync(string key, byte[] data, CancellationToken ct = default)
        {
            // Allow masterkey/vault reads path during unlock... unlock only gets. After unlock,
            // first puts during rename should fail. Skip failing for zero-byte? Always fail put.
            _puts++;
            return Task.FromException(new ObjectStoreException("simulated remote put failure (non-2xx)"));
        }
        public Task PutObjectAsync(string key, string sourceFilePath, CancellationToken ct = default) =>
            PutObjectAsync(key, Array.Empty<byte>(), ct);
        public Task DeleteObjectAsync(string key, CancellationToken ct = default) =>
            _inner.DeleteObjectAsync(key, ct);
    }
}
