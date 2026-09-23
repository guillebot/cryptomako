using CryptoMako.Vault;
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

        var status = provider.GetStatus();
        Assert.False(status.Registered);
        Assert.False(status.SessionAttached);
        if (!provider.IsWindowsCloudFilesAvailable)
            Assert.Throws<PlatformNotSupportedException>(() => provider.RegisterSyncRoot("test"));
    }

    [Fact]
    public void CloudFilesProvider_register_unregister_on_windows()
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
            var st = provider.GetStatus();
            Assert.True(st.Registered);
            Assert.True(st.PlatformSupported);
            Assert.NotNull(st.PlatformInfo);

            provider.UnregisterSyncRoot();
            Assert.False(provider.GetStatus().Registered);
        }
        finally
        {
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
}
