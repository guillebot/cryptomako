using CryptoMako.Vault;
using CryptoMako.S3;
using CryptoMako.App;
using CryptoMako.CfApi;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class AppShellTests
{
    [Fact]
    public void CloudFilesProvider_reports_platform_and_fail_closed_policy()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-cfapi-" + Guid.NewGuid().ToString("N"));
        using var provider = new CloudFilesProvider(root);
        Assert.Equal(OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134), provider.IsWindowsCloudFilesAvailable);
        Assert.True(CloudFilesProvider.IsDurableSuccess(true));
        Assert.False(CloudFilesProvider.IsDurableSuccess(false));
        Assert.Throws<InvalidOperationException>(() =>
            CloudFilesProvider.AcknowledgeWriteOnlyIfRemoteOk(false));
        CloudFilesProvider.AcknowledgeWriteOnlyIfRemoteOk(true);

        Assert.Contains("Partial", CloudFilesProvider.SyncPolicySummary, StringComparison.Ordinal);
        Assert.Contains("AutoDehydrationAllowed", CloudFilesProvider.SyncPolicySummary, StringComparison.Ordinal);
        Assert.Contains("population=Full", CloudFilesProvider.SyncPolicySummary, StringComparison.Ordinal);
        Assert.DoesNotContain("population=Partial", CloudFilesProvider.SyncPolicySummary, StringComparison.Ordinal);
        Assert.DoesNotContain("AlwaysFull", CloudFilesProvider.SyncPolicySummary, StringComparison.Ordinal);
        var status = provider.GetStatus();
        Assert.Equal(CloudFilesProvider.SyncPolicySummary, status.PolicySummary);
        Assert.False(status.Registered);
        Assert.False(status.SessionAttached);
        if (!provider.IsWindowsCloudFilesAvailable)
            Assert.Throws<PlatformNotSupportedException>(() => provider.RegisterSyncRoot("test"));
    }

    [Fact]
    public void CloudFilesProvider_register_connect_unregister_on_windows()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return;

        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CryptoMako",
            "cfapi-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var provider = new CloudFilesProvider(root);
        try
        {
            provider.RegisterSyncRoot("test-account");
            Assert.True(provider.GetStatus().Registered);

            provider.Connect();
            Assert.True(provider.GetStatus().Connected);

            provider.Disconnect();
            Assert.False(provider.GetStatus().Connected);

            provider.UnregisterSyncRoot();
            Assert.False(provider.GetStatus().Registered);
        }
        finally
        {
            try { provider.Disconnect(); } catch { }
            try { if (provider.GetStatus().Registered) provider.UnregisterSyncRoot(); } catch { }
            try { Directory.Delete(root, true); } catch { }
        }
    }

    [Fact]
    public async Task CloudFilesProvider_placeholder_from_fixture_on_windows()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return;

        var repoRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));
        var fixture = Path.Combine(repoRoot, "fixtures", "vault");
        var passPath = Path.Combine(repoRoot, "fixtures", "PASSWORD");
        if (!Directory.Exists(fixture) || !File.Exists(passPath))
            return; // fixtures absent (CI without golden vault)

        var pass = File.ReadAllText(passPath).TrimEnd('\n', '\r');
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CryptoMako",
            "cfapi-ph-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);

        await using var session = VaultSession.UnlockLocal(fixture, pass);
        using var provider = new CloudFilesProvider(root);
        try
        {
            provider.RegisterSyncRoot("placeholder-smoke");
            provider.Connect();
            provider.AttachSession(session);

            var n = provider.CreatePlaceholders(new[]
            {
                new CloudFilesPlaceholder
                {
                    CleartextRelativePath = "hello.txt",
                    CiphertextKey = "",
                    IsDirectory = false,
                    FileSize = "hello cryptomako\n".Length,
                },
            });
            Assert.True(n >= 1);
            Assert.True(File.Exists(Path.Combine(root, "hello.txt")) ||
                        Directory.Exists(Path.Combine(root, "hello.txt")) ||
                        // placeholder may appear as reparse point file
                        File.Exists(Path.Combine(root, "hello.txt")));

            // Placeholder path should exist as a cloud file
            var ph = Path.Combine(root, "hello.txt");
            Assert.True(File.Exists(ph));
        }
        finally
        {
            try { provider.Disconnect(); } catch { }
            try { if (provider.GetStatus().Registered) provider.UnregisterSyncRoot(); } catch { }
            try { Directory.Delete(root, true); } catch { }
        }
    }

    [Fact]
    public void MainViewModel_save_reload_settings_roundtrip()
    {
        var dir = Path.Combine(Path.GetTempPath(), "cm-app-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var settingsPath = Path.Combine(dir, "settings.json");
        var prefsPath = Path.Combine(dir, "prefs.json");

        var settings = new VaultSettings
        {
            StorageMode = "local",
            LocalVaultPath = "/tmp/vault",
            PathStyle = true,
        };
        settings.SaveToFile(settingsPath);
        var back = VaultSettings.LoadFromFile(settingsPath);
        Assert.True(back.IsLocal);
        Assert.Equal("/tmp/vault", back.LocalVaultPath);

        var prefs = new AppPreferences { ProxyMode = "direct", SyncSmallPutConcurrency = 8 };
        File.WriteAllText(prefsPath, prefs.Serialize());
        var prefsBack = AppPreferences.Deserialize(File.ReadAllText(prefsPath));
        Assert.Equal("direct", prefsBack.ProxyMode);
        Assert.Equal(8, prefsBack.SyncSmallPutConcurrency);

        Assert.Equal("direct", ProxyHttp.Describe(prefsBack));
    }

    [Fact]
    public async Task S3Probe_local_mode_skips()
    {
        var result = await S3Probe.ProbeAsync(new VaultSettings { StorageMode = "local", LocalVaultPath = "/x" }, secretKey: null);
        Assert.Equal(ProbeLamp.Skip, result.Dns);
        Assert.Equal("local mode", result.Detail);
    }

    [Fact]
    public async Task MainViewModel_LockAsync_clears_Password_field()
    {
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        vm.Password = "temporary-ui-passphrase";
        Assert.Equal("temporary-ui-passphrase", vm.Password);
        await vm.LockAsync();
        Assert.Equal("", vm.Password);
        Assert.False(vm.IsUnlocked);
        Assert.Equal("locked", vm.Status);
    }
    private sealed class FakeExplorerViewer : IExplorerViewer
    {
        public bool IsConnected { get; set; } = true;
        public int DisconnectCalls { get; private set; }
        public void Disconnect()
        {
            DisconnectCalls++;
            IsConnected = false;
        }
    }

    private sealed class TrackingSecretStore : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new(StringComparer.Ordinal);
        public int DeleteCalls { get; private set; }
        public bool IsPersistent => false;
        public string? GetSecret(string account) => _map.TryGetValue(account, out var v) ? v : null;
        public void SetSecret(string account, string value) => _map[account] = value;
        public void DeleteSecret(string account)
        {
            DeleteCalls++;
            _map.Remove(account);
        }
    }

    [Fact]
    public async Task MainViewModel_LockAsync_disconnects_explorer_viewer()
    {
        var viewer = new FakeExplorerViewer { IsConnected = true };
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        vm.BindExplorerViewer(viewer);
        Assert.True(vm.IsExplorerViewerConnected);
        await vm.LockAsync();
        Assert.Equal(1, viewer.DisconnectCalls);
        Assert.False(viewer.IsConnected);
        Assert.Null(vm.ExplorerViewer);
        Assert.False(vm.IsExplorerViewerConnected);
    }

    [Fact]
    public async Task MainViewModel_BindExplorerViewer_assign_and_clear()
    {
        var viewer = new FakeExplorerViewer { IsConnected = true };
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        vm.BindExplorerViewer(viewer);
        Assert.Same(viewer, vm.ExplorerViewer);
        Assert.True(vm.IsExplorerViewerConnected);
        vm.DisconnectExplorerViewer();
        Assert.Equal(1, viewer.DisconnectCalls);
        Assert.Null(vm.ExplorerViewer);
        Assert.False(vm.IsExplorerViewerConnected);
    }

    [Fact]
    public async Task MainViewModel_DisconnectExplorerViewer_noop_when_unset()
    {
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        vm.DisconnectExplorerViewer(); // must not throw
        Assert.Null(vm.ExplorerViewer);
    }

    [Fact]
    public async Task MainViewModel_LockAsync_does_not_wipe_secret_store()
    {
        var store = new TrackingSecretStore();
        store.SetSecret(SecretAccounts.Password, "vault-pass");
        store.SetSecret(SecretAccounts.SecretKey, "s3-secret");
        await using var vm = new MainViewModel(secrets: store);
        await vm.LockAsync();
        Assert.Equal(0, store.DeleteCalls);
        Assert.Equal("vault-pass", store.GetSecret(SecretAccounts.Password));
        Assert.Equal("s3-secret", store.GetSecret(SecretAccounts.SecretKey));
    }

    [Fact]
    public async Task MainViewModel_LockAsync_cancels_backup_sync_cts()
    {
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        // Reflect into private CTS to simulate an in-flight sync without hitting the network.
        var field = typeof(MainViewModel).GetField("_backupSyncCts",
            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        Assert.NotNull(field);
        var cts = new CancellationTokenSource();
        field!.SetValue(vm, cts);
        Assert.True(vm.IsBackupSyncRunning);
        await vm.LockAsync();
        Assert.True(cts.IsCancellationRequested);
        Assert.False(vm.IsBackupSyncRunning);
    }

    [Fact]
    public async Task MainViewModel_TransferRunVerb_follows_backupTransferMode()
    {
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        vm.BackupTransferMode = AppPreferences.BackupTransferModeBackup;
        Assert.Equal("Backup all", vm.TransferRunAllLabel);
        Assert.Equal("Backup", vm.TransferRunVerb);
        vm.BackupTransferMode = AppPreferences.BackupTransferModeSync;
        Assert.Equal("Sync all", vm.TransferRunAllLabel);
        Assert.Equal("Sync", vm.TransferRunVerb);
    }

    [Fact]
    public async Task MainViewModel_SyncAsync_requires_unlock_before_source_filter()
    {
        await using var vm = new MainViewModel(secrets: new EnvSecretStore());
        var ex = await Assert.ThrowsAsync<InvalidOperationException>(() => vm.SyncAsync("missing-source-id"));
        Assert.Contains("unlock", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task MainViewModel_MarkBackupSourceFullySynced_only_stamps_matching_source()
    {
        var path = Path.Combine(Path.GetTempPath(), "cm-mark-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new BackupSourcesStore();
            var a = BackupSource.Create(Path.GetTempPath(), "HostA");
            var b = BackupSource.Create(Path.GetTempPath(), "HostB");
            store.Sources.Add(a);
            store.Sources.Add(b);
            store.SaveToFile(path);

            await using var vm = new MainViewModel(secrets: new EnvSecretStore());
            // Point VM at our temp store via reload trick: replace BackupSources through disk path.
            // AppPaths.BackupSourcesPath is fixed; inject by writing default path if needed.
            // Use reflection to set BackupSources for this unit test.
            var prop = typeof(MainViewModel).GetProperty(nameof(MainViewModel.BackupSources));
            Assert.NotNull(prop);
            var loaded = BackupSourcesStore.LoadFromFile(path);
            prop!.SetValue(vm, loaded);

            var stamp = DateTimeOffset.Parse("2026-01-15T12:00:00Z");
            vm.MarkBackupSourceFullySynced(a.Id, stamp);

            Assert.NotNull(loaded.Sources[0].LastFullSyncAt);
            Assert.Equal(stamp.UtcTicks, loaded.Sources[0].LastFullSyncAt!.Value.UtcTicks);
            Assert.Null(loaded.Sources[1].LastFullSyncAt);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }

    [Fact]
    public void S3Settings_ClearSecretKey_drops_reference()
    {
        var s = S3Settings.From("https://s3.example/", "us-east-1", "b", "AKIA", "supersecret", pathStyle: true);
        Assert.Equal("supersecret", s.SecretKey);
        s.ClearSecretKey();
        Assert.Equal("", s.SecretKey);
    }
}
