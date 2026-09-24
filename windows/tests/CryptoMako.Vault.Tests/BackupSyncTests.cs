using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupSyncTests
{
    [Fact]
    public void Excludes_match_directory_file_extension_and_relative()
    {
        var e = new BackupSyncExcludes();
        Assert.True(e.ShouldSkipDirectory("node_modules"));
        Assert.True(e.ShouldSkipFile(".DS_Store"));
        Assert.True(e.ShouldSkipFile("x.pyc"));
        Assert.False(e.ShouldSkipFile("readme.md"));
        Assert.True(e.ShouldSkipRelativePath("src/node_modules/pkg/index.js"));
        Assert.True(e.ShouldSkipRelativePath("foo/Thumbs.db"));
        Assert.False(e.ShouldSkipRelativePath("src/app.cs"));
    }

    [Fact]
    public void Worker_clamps_and_bandwidth_helpers()
    {
        var p = new AppPreferences
        {
            SyncSmallPutConcurrency = 0,
            SyncMediumPutConcurrency = 999,
            SyncLargePutConcurrency = -3,
            LimitSyncUploadBandwidth = true,
            SyncUploadCapMbps = 0.25,
        };
        Assert.Equal(1, p.ClampedSmallPutConcurrency);
        Assert.Equal(128, p.ClampedMediumPutConcurrency);
        Assert.Equal(1, p.ClampedLargePutConcurrency);
        p.ClampSyncWorkers();
        Assert.Equal(1, p.SyncUploadCapMbps);
        Assert.NotNull(p.SyncUploadBytesPerSecond);
        Assert.Equal(1_000_000 / 8.0, p.SyncUploadBytesPerSecond!.Value, 3);
    }

    [Fact]
    public void ProxyHttp_describe_modes()
    {
        Assert.Equal("system", ProxyHttp.Describe(new AppPreferences { ProxyMode = "system" }));
        Assert.Equal("direct", ProxyHttp.Describe(new AppPreferences { ProxyMode = "direct" }));
        Assert.Equal("custom:proxy.example:3128", ProxyHttp.Describe(new AppPreferences
        {
            ProxyMode = "custom",
            ProxyHost = "proxy.example",
            ProxyPort = 3128,
        }));
        Assert.Equal("custom:invalid", ProxyHttp.Describe(new AppPreferences
        {
            ProxyMode = "custom",
            ProxyHost = "",
            ProxyPort = 0,
        }));

        using var direct = (SocketsHttpHandler)ProxyHttp.CreateHandler(new AppPreferences { ProxyMode = "direct" });
        Assert.False(direct.UseProxy);

        using var custom = (SocketsHttpHandler)ProxyHttp.CreateHandler(new AppPreferences
        {
            ProxyMode = "custom",
            ProxyHost = "127.0.0.1",
            ProxyPort = 8080,
            ProxyUsername = "u",
        }, proxyPassword: "p");
        Assert.True(custom.UseProxy);
        Assert.NotNull(custom.Proxy);
    }

    [Fact]
    public void Encrypt_decrypt_content_and_filename_roundtrip()
    {
        var aes = new byte[32]; var mac = new byte[32];
        RandomNumberGenerator.Fill(aes); RandomNumberGenerator.Fill(mac);
        using var mk = new Masterkey(aes, mac);
        using var cryptor = new Cryptor(mk);
        var dirId = Encoding.UTF8.GetBytes("parent");
        var encName = cryptor.EncryptFileName("hello.txt", dirId);
        Assert.Equal("hello.txt", cryptor.DecryptFileName(encName, dirId));

        var clear = Encoding.UTF8.GetBytes("hello cryptomako\n");
        var cipher = cryptor.EncryptContent(clear);
        Assert.Equal(clear, cryptor.DecryptContent(cipher));

        // empty file
        var emptyCipher = cryptor.EncryptContent(ReadOnlySpan<byte>.Empty);
        Assert.Equal(Cryptor.FileHeaderSize, emptyCipher.Length);
        Assert.Empty(cryptor.DecryptContent(emptyCipher));
    }

    [Fact]
    public async Task BackupSync_uploads_to_local_vault_under_Backups()
    {
        var vaultDir = Path.Combine(Path.GetTempPath(), "cm-vault-" + Guid.NewGuid().ToString("N"));
        var sourceDir = Path.Combine(Path.GetTempPath(), "cm-src-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sourceDir);
        Directory.CreateDirectory(Path.Combine(sourceDir, "sub"));
        Directory.CreateDirectory(Path.Combine(sourceDir, "node_modules", "pkg"));
        await File.WriteAllTextAsync(Path.Combine(sourceDir, "a.txt"), "alpha\n");
        await File.WriteAllTextAsync(Path.Combine(sourceDir, "sub", "b.txt"), "beta\n");
        await File.WriteAllTextAsync(Path.Combine(sourceDir, "node_modules", "pkg", "skip.js"), "nope\n");
        await File.WriteAllTextAsync(Path.Combine(sourceDir, "x.pyc"), "bytecode");

        try
        {
            // Minimal vault: create masterkey+jwt via Swift fixture is heavy; reuse golden unlock then sync into a copy?
            // Instead: unlock golden fixture and sync into it under Backups/ (mutates gitignored vault — OK).
            var fixture = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "fixtures", "vault"));
            Assert.True(Directory.Exists(fixture));
            var passPath = Path.GetFullPath(Path.Combine(fixture, "..", "PASSWORD"));
            var pass = File.ReadAllText(passPath).TrimEnd('\n', '\r');

            // Work on a disposable copy of the vault so we do not dirty shared fixtures unexpectedly mid-flight of other tests.
            CopyDir(fixture, vaultDir);
            await using var session = VaultSession.UnlockLocal(vaultDir, pass);

            var prefs = new AppPreferences
            {
                SyncSmallPutConcurrency = 4,
                SyncMediumPutConcurrency = 2,
                SyncLargePutConcurrency = 1,
            };
            var engine = new BackupSyncEngine();
            var statePath = Path.Combine(Path.GetTempPath(), "cm-sync-state-" + Guid.NewGuid().ToString("N") + ".json");
            var result = await engine.SyncAsync(session, sourceDir, "TestHost", prefs, syncStatePath: statePath);
            Assert.Equal(2, result.FilesUploaded); // a.txt + sub/b.txt; excludes skip node_modules + pyc
            Assert.Equal(0, result.FilesSkipped);

            var listing = await session.ListAsync("/Backups/TestHost", recursive: true);
            Assert.Contains("/Backups/TestHost/a.txt", listing);
            Assert.Contains("/Backups/TestHost/sub/", listing);
            Assert.Contains("/Backups/TestHost/sub/b.txt", listing);
            Assert.DoesNotContain(listing, x => x.Contains("skip.js", StringComparison.Ordinal));
            Assert.DoesNotContain(listing, x => x.Contains(".pyc", StringComparison.Ordinal));

            var again = await engine.SyncAsync(session, sourceDir, "TestHost", prefs, syncStatePath: statePath);
            Assert.Equal(0, again.FilesUploaded);
            Assert.Equal(2, again.FilesSkipped);
        }
        finally
        {
            try { Directory.Delete(sourceDir, true); } catch { /* ignore */ }
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void CompositeSecretStore_reads_env()
    {
        var name = "CRYPTOMAKO_TEST_SECRET_" + Guid.NewGuid().ToString("N");
        try
        {
            Environment.SetEnvironmentVariable(name, "value");
            var store = new CompositeSecretStore();
            Assert.Equal("value", store.GetSecret(name));
            Assert.Equal(OperatingSystem.IsWindows(), WindowsCredentialStore.IsSupported);
        }
        finally
        {
            Environment.SetEnvironmentVariable(name, null);
        }
    }


    [Fact]
    public async Task Sync_reports_scanning_progress_with_names_before_upload()
    {
        var vaultDir = Path.Combine(Path.GetTempPath(), "cm-vault-scan-" + Guid.NewGuid().ToString("N"));
        var sourceDir = Path.Combine(Path.GetTempPath(), "cm-src-scan-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sourceDir);
        // Enough files that throttle fires multiple times.
        for (var i = 0; i < 80; i++)
            await File.WriteAllTextAsync(Path.Combine(sourceDir, $"f{i:D3}.txt"), "x" + i);

        try
        {
            var fixture = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "fixtures", "vault"));
            Assert.True(Directory.Exists(fixture));
            var passPath = Path.GetFullPath(Path.Combine(fixture, "..", "PASSWORD"));
            var pass = File.ReadAllText(passPath).TrimEnd('\n', '\r');
            CopyDir(fixture, vaultDir);
            await using var session = VaultSession.UnlockLocal(vaultDir, pass);

            // Synchronous IProgress: Progress<T> posts to ThreadPool when no SyncContext,
            // so updates can still be in-flight after SyncAsync returns.
            var scanning = new List<BackupSyncProgressUpdate>();
            var progress = new SyncProgressCollector(scanning);

            var engine = new BackupSyncEngine();
            var result = await engine.SyncAsync(
                session,
                sourceDir,
                "ScanProgTest",
                new AppPreferences(),
                syncProgress: progress);

            Assert.True(scanning.Count >= 2, $"expected multiple live scanning updates, got {scanning.Count}");
            Assert.Contains(scanning, u => !string.IsNullOrEmpty(u.CurrentPath) && u.CurrentPath.EndsWith(".txt", StringComparison.Ordinal));
            Assert.True(scanning[^1].FilesScanned >= 80);
            Assert.Equal(80, result.FilesScanned);
            // Labels must stay in Counting form (not 100% percent branch).
            var mid = scanning[scanning.Count / 2];
            var label = CryptoMako.App.MainViewModel.BuildBackupProgressLabel(mid);
            Assert.StartsWith("Counting local files...", label);
            Assert.DoesNotContain("%", label);
        }
        finally
        {
            try { Directory.Delete(sourceDir, true); } catch { /* ignore */ }
            try { Directory.Delete(vaultDir, true); } catch { /* ignore */ }
        }
    }


    private sealed class SyncProgressCollector : IProgress<BackupSyncProgressUpdate>
    {
        private readonly List<BackupSyncProgressUpdate> _scanning;
        public SyncProgressCollector(List<BackupSyncProgressUpdate> scanning) => _scanning = scanning;
        public void Report(BackupSyncProgressUpdate value)
        {
            if (value.Phase == "scanning" && value.FilesScanned > 0)
                _scanning.Add(value);
        }
    }

    private static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var dir in Directory.GetDirectories(src, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(dir.Replace(src, dst));
        }
        foreach (var file in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
        {
            var target = file.Replace(src, dst);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(file, target, overwrite: true);
        }
    }
}
