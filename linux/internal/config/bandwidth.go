package config

import (
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

// Acquire blocks until byteCount tokens are available, then consumes them.
func (l *UploadBandwidthLimiter) Acquire(byteCount int64) {
	if l == nil || l.rateBytesPerSec <= 0 || byteCount <= 0 {
		return
	}
	need := float64(byteCount)
	for {
		var sleepSeconds float64
		l.mu.Lock()
		l.refillLocked()
		if l.tokens >= need {
			l.tokens -= need
			l.mu.Unlock()
			return
		}
		deficit := need - l.tokens
		l.tokens = 0
		l.lastRefill = time.Now()
		sleepSeconds = deficit / l.rateBytesPerSec
		l.mu.Unlock()
		if sleepSeconds <= 0 {
			return
		}
		if sleepSeconds > 2 {
			sleepSeconds = 2
		}
		time.Sleep(time.Duration(sleepSeconds * float64(time.Second)))
	}
}

func (l *UploadBandwidthLimiter) refillLocked() {
	now := time.Now()
	elapsed := now.Sub(l.lastRefill).Seconds()
	if elapsed <= 0 {
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
