using System.Diagnostics;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class UploadBandwidthLimiterTests
{
    [Fact]
    public async Task File_larger_than_burst_completes()
    {
        var lim = new UploadBandwidthLimiter(10_000); // 10 KB/s, burst 10 KB
        var sw = Stopwatch.StartNew();
        var acquire = lim.AcquireAsync(25_000); // ~1.5s after the burst
        var winner = await Task.WhenAny(acquire, Task.Delay(TimeSpan.FromSeconds(6)));
        Assert.Same(acquire, winner);
        await acquire;
        Assert.InRange(sw.Elapsed.TotalSeconds, 1.0, 4.0);
    }

    [Fact]
    public async Task Disable_mid_acquire_returns_promptly()
    {
        var lim = new UploadBandwidthLimiter(8_000);
        await lim.AcquireAsync(8_000); // burn burst
        var acquire = lim.AcquireAsync(80_000); // ~10s at 8 KB/s
        await Task.Delay(200);
        lim.SetBytesPerSecond(0);
        var winner = await Task.WhenAny(acquire, Task.Delay(TimeSpan.FromSeconds(2)));
        Assert.Same(acquire, winner);
        Assert.Equal(0, lim.BytesPerSecond);
    }

    [Fact]
    public async Task Raise_cap_mid_acquire_applies()
    {
        var lim = new UploadBandwidthLimiter(1_000);
        await lim.AcquireAsync(1_000);
        var acquire = lim.AcquireAsync(100_000); // ~100s at 1 KB/s
        await Task.Delay(100);
        lim.SetBytesPerSecond(1_000_000);
        var winner = await Task.WhenAny(acquire, Task.Delay(TimeSpan.FromSeconds(2)));
        Assert.Same(acquire, winner);
    }

    [Fact]
    public async Task Live_limiter_hot_reloads_from_preferences()
    {
        var prefs = new AppPreferences();
        var lim = UploadBandwidthLimiter.Live(prefs);
        Assert.Equal(0, lim.BytesPerSecond);
        await lim.AcquireAsync(1L << 30); // unlimited: immediate
        prefs.LimitSyncUploadBandwidth = true;
        prefs.SyncUploadCapMbps = 10;
        lim.ApplyPreferences(prefs);
        Assert.Equal(10 * 1_000_000 / 8.0, lim.BytesPerSecond, 3);
        prefs.LimitSyncUploadBandwidth = false;
        lim.ApplyPreferences(prefs);
        Assert.Equal(0, lim.BytesPerSecond);
    }

    [Fact]
    public async Task Cancel_mid_acquire_throws()
    {
        var lim = new UploadBandwidthLimiter(1_000);
        await lim.AcquireAsync(1_000);
        using var cts = new CancellationTokenSource(100);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => lim.AcquireAsync(100_000, cts.Token));
    }
}
