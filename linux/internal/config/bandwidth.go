package config

import (
	"context"
	"sync"
	"time"
)

// UploadBandwidthLimiter is a token-bucket limiter for Backup Sync put pacing
// (cleartext-byte budget). Mirrors macOS UploadBandwidthLimiter.
type UploadBandwidthLimiter struct {
	rateBytesPerSec float64
	mu              sync.Mutex
	tokens          float64
	lastRefill      time.Time
}

// NewUploadBandwidthLimiter creates a limiter. rateBytesPerSec ≤ 0 disables.
func NewUploadBandwidthLimiter(rateBytesPerSec float64) *UploadBandwidthLimiter {
	if rateBytesPerSec < 0 {
		rateBytesPerSec = 0
	}
	return &UploadBandwidthLimiter{
		rateBytesPerSec: rateBytesPerSec,
		tokens:          rateBytesPerSec, // 1s burst
		lastRefill:      time.Now(),
	}
}

// UploadBandwidthLimiterFromPreferences returns a limiter or nil when unlimited.
func UploadBandwidthLimiterFromPreferences(prefs AppPreferences) *UploadBandwidthLimiter {
	rate := prefs.SyncUploadBytesPerSecond()
	if rate <= 0 {
		return nil
	}
	return NewUploadBandwidthLimiter(rate)
}

// LiveUploadBandwidthLimiter always returns a limiter (rate 0 = unlimited) so
// Sync can hot-reload the cap without recreating the shared instance.
func LiveUploadBandwidthLimiter(prefs AppPreferences) *UploadBandwidthLimiter {
	return NewUploadBandwidthLimiter(prefs.SyncUploadBytesPerSecond())
}

// ApplyPreferences hot-reloads the Mbps cap (0 = unlimited). Safe mid-Acquire.
func (l *UploadBandwidthLimiter) ApplyPreferences(prefs AppPreferences) {
	if l == nil {
		return
	}
	l.SetBytesPerSecond(prefs.SyncUploadBytesPerSecond())
}

// SetBytesPerSecond updates the sustained budget. 0 disables pacing.
func (l *UploadBandwidthLimiter) SetBytesPerSecond(rateBytesPerSec float64) {
	if l == nil {
		return
	}
	if rateBytesPerSec < 0 {
		rateBytesPerSec = 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.rateBytesPerSec > 0 {
		l.refillLocked()
	}
	enabling := l.rateBytesPerSec <= 0 && rateBytesPerSec > 0
	l.rateBytesPerSec = rateBytesPerSec
	if rateBytesPerSec <= 0 {
		l.tokens = 0
	} else if enabling {
		l.tokens = rateBytesPerSec
	} else if l.tokens > rateBytesPerSec {
		l.tokens = rateBytesPerSec
	}
	l.lastRefill = time.Now()
}

// BytesPerSecond is the current budget (0 = unlimited). For tests / diagnostics.
func (l *UploadBandwidthLimiter) BytesPerSecond() float64 {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.rateBytesPerSec
}

// maxAcquireSlice bounds each wait so cancel and live rate changes apply promptly.
const maxAcquireSlice = 250 * time.Millisecond

// Acquire consumes byteCount tokens as the bucket refills (macOS PR #40 parity).
//
//   - Never requires byteCount ≤ burst (1s of rate): takes whatever is available
//     each pass, so files larger than the burst always finish.
//   - Re-reads the rate every pass: switching to unlimited (0) mid-wait returns
//     promptly; a changed Mbps applies to the remaining charge.
//   - Sleeps in slices of at most 250ms.
func (l *UploadBandwidthLimiter) Acquire(byteCount int64) {
	l.AcquireContext(context.Background(), byteCount)
}

// AcquireContext is Acquire that also returns early when ctx is cancelled.
func (l *UploadBandwidthLimiter) AcquireContext(ctx context.Context, byteCount int64) {
	if l == nil || byteCount <= 0 {
		return
	}
	if ctx == nil {
		ctx = context.Background()
	}
	remaining := float64(byteCount)
	for remaining > 0 {
		if ctx.Err() != nil {
			return
		}
		l.mu.Lock()
		if l.rateBytesPerSec <= 0 {
			l.mu.Unlock()
			return
		}
		l.refillLocked()
		take := minFloat(l.tokens, remaining)
		if take > 0 {
			l.tokens -= take
			remaining -= take
		}
		var wait time.Duration
		if remaining > 0 {
			want := minFloat(remaining, l.rateBytesPerSec) // at most 1s of refill
			wait = time.Duration(want / l.rateBytesPerSec * float64(time.Second))
		}
		l.mu.Unlock()
		if remaining <= 0 {
			return
		}
		if wait > maxAcquireSlice {
			wait = maxAcquireSlice
		}
		if wait < time.Millisecond {
			wait = time.Millisecond
		}
		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return
		case <-t.C:
		}
	}
}

func (l *UploadBandwidthLimiter) refillLocked() {
	now := time.Now()
	elapsed := now.Sub(l.lastRefill).Seconds()
	if elapsed <= 0 || l.rateBytesPerSec <= 0 {
		return
	}
	l.tokens = minFloat(l.rateBytesPerSec, l.tokens+elapsed*l.rateBytesPerSec)
	l.lastRefill = now
}

func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
