package config

import (
	"context"
	"os"
	"time"
)

// DefaultPreferencesWatchInterval is how often a running Sync polls
// app-preferences.json for a changed bandwidth cap (Linux analog of the macOS
// AppPreferences.didSaveNotification hot-reload).
const DefaultPreferencesWatchInterval = time.Second

// WatchAppPreferences polls path (default XDG) every interval and calls
// onChange with freshly loaded prefs whenever the file's mtime or size changes
// (including appearing or disappearing). It returns when ctx is done. Runs on
// the caller's goroutine — start it with `go`.
func WatchAppPreferences(ctx context.Context, path string, interval time.Duration, onChange func(AppPreferences)) {
	if onChange == nil {
		return
	}
	if path == "" {
		path = DefaultPreferencesPath()
	}
	if interval <= 0 {
		interval = DefaultPreferencesWatchInterval
	}
	type stamp struct {
		exists bool
		mod    time.Time
		size   int64
	}
	read := func() stamp {
		fi, err := os.Stat(path)
		if err != nil {
			return stamp{}
		}
		return stamp{exists: true, mod: fi.ModTime(), size: fi.Size()}
	}
	last := read()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cur := read()
			if cur == last {
				continue
			}
			last = cur
			onChange(LoadAppPreferences(path))
		}
	}
}

// WatchBandwidthCap hot-reloads limiter from path until ctx is done.
// Only the bandwidth cap is live; worker counts / excludes apply next Sync.
func WatchBandwidthCap(ctx context.Context, path string, interval time.Duration, limiter *UploadBandwidthLimiter) {
	if limiter == nil {
		return
	}
	WatchAppPreferences(ctx, path, interval, limiter.ApplyPreferences)
}
