package config

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Regression: macOS PR #40 deadlock. A file larger than the 1s burst must
// still finish acquiring (chunked takes), in roughly size/rate seconds.
func TestBandwidthLimiterFileLargerThanBurstCompletes(t *testing.T) {
	lim := NewUploadBandwidthLimiter(10_000) // 10 KB/s, burst 10 KB
	done := make(chan time.Duration, 1)
	start := time.Now()
	go func() {
		lim.Acquire(25_000) // 2.5× burst: 10 KB now + 15 KB over ~1.5s
		done <- time.Since(start)
	}()
	select {
	case elapsed := <-done:
		if elapsed < 1200*time.Millisecond || elapsed > 3*time.Second {
			t.Fatalf("elapsed=%v, want ~1.5s", elapsed)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("Acquire larger than burst hung (deadlock regression)")
	}
}

func TestBandwidthLimiterDisableMidAcquireReturnsPromptly(t *testing.T) {
	lim := NewUploadBandwidthLimiter(8_000)
	lim.Acquire(8_000) // burn burst
	done := make(chan struct{})
	go func() {
		lim.Acquire(80_000) // ~10s at 8 KB/s
		close(done)
	}()
	time.Sleep(200 * time.Millisecond)
	lim.SetBytesPerSecond(0)
	start := time.Now()
	select {
	case <-done:
		if time.Since(start) > time.Second {
			t.Fatalf("took %v after disable", time.Since(start))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Acquire did not return after disabling")
	}
	if lim.BytesPerSecond() != 0 {
		t.Fatalf("rate=%v", lim.BytesPerSecond())
	}
}

func TestBandwidthLimiterRaiseCapMidAcquire(t *testing.T) {
	lim := NewUploadBandwidthLimiter(1_000)
	lim.Acquire(1_000)
	done := make(chan struct{})
	go func() {
		lim.Acquire(100_000) // ~100s at 1 KB/s
		close(done)
	}()
	time.Sleep(100 * time.Millisecond)
	lim.SetBytesPerSecond(1_000_000) // 1 MB/s → remaining in ~0.1s
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("raised cap did not apply to in-flight Acquire")
	}
}

func TestBandwidthLimiterContextCancel(t *testing.T) {
	lim := NewUploadBandwidthLimiter(1_000)
	lim.Acquire(1_000)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		lim.AcquireContext(ctx, 100_000)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("AcquireContext ignored cancel")
	}
}

func TestLiveLimiterApplyPreferences(t *testing.T) {
	p := DefaultAppPreferences()
	lim := LiveUploadBandwidthLimiter(p)
	if lim == nil || lim.BytesPerSecond() != 0 {
		t.Fatal("live limiter must exist and be unlimited by default")
	}
	lim.Acquire(1 << 30) // unlimited: no-op
	p.LimitSyncUploadBandwidth = true
	p.SyncUploadCapMbps = 10
	lim.ApplyPreferences(p)
	if got := lim.BytesPerSecond(); got != 10*1_000_000/8 {
		t.Fatalf("rate=%v", got)
	}
	p.LimitSyncUploadBandwidth = false
	lim.ApplyPreferences(p)
	if lim.BytesPerSecond() != 0 {
		t.Fatal("expected unlimited")
	}
}

func TestWatchBandwidthCapHotReloads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "app-preferences.json")
	p := DefaultAppPreferences()
	if err := SaveAppPreferences(path, p); err != nil {
		t.Fatal(err)
	}
	lim := LiveUploadBandwidthLimiter(LoadAppPreferences(path))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go WatchBandwidthCap(ctx, path, 20*time.Millisecond, lim)
	time.Sleep(50 * time.Millisecond)
	p.LimitSyncUploadBandwidth = true
	p.SyncUploadCapMbps = 8
	if err := SaveAppPreferences(path, p); err != nil {
		t.Fatal(err)
	}
	// Ensure mtime differs even on coarse-mtime filesystems.
	future := time.Now().Add(2 * time.Second)
	_ = os.Chtimes(path, future, future)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if lim.BytesPerSecond() == 1_000_000 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("watcher did not apply cap; rate=%v", lim.BytesPerSecond())
}
