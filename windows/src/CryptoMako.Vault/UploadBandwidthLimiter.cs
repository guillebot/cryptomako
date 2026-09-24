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

    /// <summary>
    /// Consume <paramref name="byteCount"/> tokens in chunks as the bucket refills.
    /// Never requires the full size to be present at once (bucket caps at ~1s of rate).
    /// Never zeroes the bucket on deficit so concurrent waiters keep sharing refill.
    /// </summary>
    public async Task AcquireAsync(long byteCount, CancellationToken ct = default)
    {
        if (_rateBytesPerSec <= 0 || byteCount <= 0)
            return;
        var remaining = (double)byteCount;
        var maxTokens = _rateBytesPerSec;
        while (remaining > 0)
        {
            ct.ThrowIfCancellationRequested();
            double sleepSeconds;
            lock (_lock)
            {
                RefillLocked();
                if (_tokens > 0)
                {
                    var take = Math.Min(_tokens, remaining);
                    _tokens -= take;
                    remaining -= take;
                    if (remaining <= 0)
                        return;
                }
                // Do not wipe _tokens / reset refill clock — that starved peers.
                var want = Math.Min(remaining, maxTokens);
                sleepSeconds = want / _rateBytesPerSec;
            }
            var ms = (int)Math.Clamp(sleepSeconds * 1000, 1, 250);
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
