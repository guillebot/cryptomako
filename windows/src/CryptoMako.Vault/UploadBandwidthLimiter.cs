namespace CryptoMako.Vault;

/// <summary>
/// Token-bucket limiter for Backup Sync put pacing (cleartext-byte budget).
/// Rate is mutable so Settings can change Mbps (or disable limiting) mid-Sync via
/// <see cref="ApplyPreferences"/> / <see cref="SetBytesPerSecond"/> (macOS 1.0.13 parity).
/// Rate <c>0</c> = unlimited.
/// </summary>
public sealed class UploadBandwidthLimiter
{
    private readonly object _lock = new();
    private double _rateBytesPerSec;
    private double _tokens;
    private long _lastRefillTicks;

    public UploadBandwidthLimiter(double bytesPerSecond)
    {
        _rateBytesPerSec = Math.Max(0, bytesPerSecond);
        _tokens = _rateBytesPerSec; // 1s burst
        _lastRefillTicks = Environment.TickCount64;
    }

    public static UploadBandwidthLimiter? FromPreferences(AppPreferences prefs)
    {
        var rate = prefs.SyncUploadBytesPerSecond;
        return rate is double r && r > 0 ? new UploadBandwidthLimiter(r) : null;
    }

    /// <summary>Limiter that always exists (rate 0 = unlimited) so Sync can hot-reload the cap.</summary>
    public static UploadBandwidthLimiter Live(AppPreferences prefs) =>
        new(prefs.SyncUploadBytesPerSecond ?? 0);

    /// <summary>Current budget in bytes/sec (0 = unlimited). For tests / diagnostics.</summary>
    public double BytesPerSecond
    {
        get { lock (_lock) return _rateBytesPerSec; }
    }

    /// <summary>Hot-reload limit toggle + Mbps. Safe while workers are inside <see cref="AcquireAsync"/>.</summary>
    public void ApplyPreferences(AppPreferences prefs) =>
        SetBytesPerSecond(prefs.SyncUploadBytesPerSecond ?? 0);

    /// <summary>Update the sustained budget. 0 disables pacing immediately (waiters return).</summary>
    public void SetBytesPerSecond(double bytesPerSecond)
    {
        var newRate = Math.Max(0, bytesPerSecond);
        lock (_lock)
        {
            if (_rateBytesPerSec > 0)
                RefillLocked();
            var enabling = _rateBytesPerSec <= 0 && newRate > 0;
            _rateBytesPerSec = newRate;
            if (newRate <= 0)
                _tokens = 0;
            else if (enabling)
                _tokens = newRate;
            else
                _tokens = Math.Min(_tokens, newRate);
            _lastRefillTicks = Environment.TickCount64;
        }
    }

    /// <summary>
    /// Consume <paramref name="byteCount"/> tokens in chunks as the bucket refills.
    /// Never requires the full size to be present at once (bucket caps at ~1s of rate).
    /// Never zeroes the bucket on deficit so concurrent waiters keep sharing refill.
    /// Re-reads the rate every slice (≤250 ms) so a mid-Sync change applies promptly;
    /// switching to unlimited drops the remaining charge.
    /// </summary>
    public async Task AcquireAsync(long byteCount, CancellationToken ct = default)
    {
        if (byteCount <= 0)
            return;
        var remaining = (double)byteCount;
        while (remaining > 0)
        {
            ct.ThrowIfCancellationRequested();
            double sleepSeconds;
            lock (_lock)
            {
                if (_rateBytesPerSec <= 0)
                    return;
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
                var want = Math.Min(remaining, _rateBytesPerSec);
                sleepSeconds = want / _rateBytesPerSec;
            }
            var ms = (int)Math.Clamp(sleepSeconds * 1000, 1, 250);
            await Task.Delay(ms, ct).ConfigureAwait(false);
        }
    }

    private void RefillLocked()
    {
        var now = Environment.TickCount64;
        var elapsed = (now - _lastRefillTicks) / 1000.0;
        if (elapsed <= 0 || _rateBytesPerSec <= 0) return;
        _tokens = Math.Min(_rateBytesPerSec, _tokens + elapsed * _rateBytesPerSec);
        _lastRefillTicks = now;
    }
}
