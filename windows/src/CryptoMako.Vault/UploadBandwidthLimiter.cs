namespace CryptoMako.Vault;

/// <summary>Token-bucket limiter for Backup Sync put pacing (cleartext-byte budget).</summary>
public sealed class UploadBandwidthLimiter
{
    private readonly double _rateBytesPerSec;
    private readonly object _lock = new();
    private double _tokens;
    private long _lastRefillTicks;

    public UploadBandwidthLimiter(double bytesPerSecond)
    {
        _rateBytesPerSec = Math.Max(0, bytesPerSecond);
        _tokens = _rateBytesPerSec;
        _lastRefillTicks = Environment.TickCount64;
    }

    public static UploadBandwidthLimiter? FromPreferences(AppPreferences prefs)
    {
        var rate = prefs.SyncUploadBytesPerSecond;
        return rate is double r && r > 0 ? new UploadBandwidthLimiter(r) : null;
    }

    public async Task AcquireAsync(long byteCount, CancellationToken ct = default)
    {
        if (_rateBytesPerSec <= 0 || byteCount <= 0)
            return;
        var need = (double)byteCount;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            double sleepSeconds;
            lock (_lock)
            {
                RefillLocked();
                if (_tokens >= need)
                {
                    _tokens -= need;
                    return;
                }
                var deficit = need - _tokens;
                _tokens = 0;
                _lastRefillTicks = Environment.TickCount64;
                sleepSeconds = deficit / _rateBytesPerSec;
            }
            var ms = (int)Math.Clamp(sleepSeconds * 1000, 1, 2000);
            await Task.Delay(ms, ct);
        }
    }

    private void RefillLocked()
    {
        var now = Environment.TickCount64;
        var elapsed = (now - _lastRefillTicks) / 1000.0;
        if (elapsed <= 0) return;
        _tokens = Math.Min(_rateBytesPerSec, _tokens + elapsed * _rateBytesPerSec);
        _lastRefillTicks = now;
    }
}
