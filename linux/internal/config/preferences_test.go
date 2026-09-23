package config

import (
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadDefaultsWhenMissing(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	p := LoadAppPreferences("")
	def := DefaultAppPreferences()
	if p != def {
		t.Fatalf("got %+v want %+v", p, def)
	}
	if DefaultPreferencesPath() != filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "cryptomako", "app-preferences.json") {
		t.Fatalf("path = %q", DefaultPreferencesPath())
	}
}

func TestParsePartialAndUnknownKeysIgnored(t *testing.T) {
	p, err := ParseAppPreferences([]byte(`{
		"proxyMode":"custom",
		"proxyHost":"proxy.example",
		"syncSmallPutConcurrency":48,
		"futureKey":"ignored",
		"nested":{"x":1}
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if p.ProxyMode != ProxyModeCustom || p.ProxyHost != "proxy.example" {
		t.Fatalf("proxy: %+v", p)
	}
	if p.ProxyPort != 8080 {
		t.Fatalf("default port = %d", p.ProxyPort)
	}
	if p.SyncSmallPutConcurrency != 48 || p.SyncMediumPutConcurrency != 32 {
		t.Fatalf("workers: %+v", p)
	}
	if p.LimitSyncUploadBandwidth || p.SyncUploadCapMbps != 50 {
		t.Fatalf("bandwidth defaults: %+v", p)
	}
}

func TestClampAndBandwidthHelpers(t *testing.T) {
	p := AppPreferences{
		SyncSmallPutConcurrency:  0,
		SyncMediumPutConcurrency: 999,
		SyncLargePutConcurrency:  -3,
		LimitSyncUploadBandwidth: true,
		SyncUploadCapMbps:        0.25,
	}
	if p.ClampedSmallPutConcurrency() != 1 {
		t.Fatalf("small = %d", p.ClampedSmallPutConcurrency())
	}
	if p.ClampedMediumPutConcurrency() != 128 {
		t.Fatalf("medium = %d", p.ClampedMediumPutConcurrency())
	}
	if p.ClampedLargePutConcurrency() != 1 {
		t.Fatalf("large = %d", p.ClampedLargePutConcurrency())
	}
	p.ClampSyncWorkers()
	if p.SyncUploadCapMbps != 1 {
		t.Fatalf("cap = %v", p.SyncUploadCapMbps)
	}
	rate := p.SyncUploadBytesPerSecond()
	if rate != 1_000_000/8.0 {
		t.Fatalf("rate = %v", rate)
	}
	off := DefaultAppPreferences()
	if off.SyncUploadBytesPerSecond() != 0 {
		t.Fatal("unlimited should be 0")
	}
}

func TestRejectSecretsInPreferencesJSON(t *testing.T) {
	_, err := ParseAppPreferences([]byte(`{"proxyMode":"system","proxyPassword":"nope"}`))
	if err == nil {
		t.Fatal("expected reject proxyPassword")
	}
}

func TestSaveRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "app-preferences.json")
	in := AppPreferences{
		ProxyMode:                ProxyModeCustom,
		ProxyHost:                "127.0.0.1",
		ProxyPort:                3128,
		ProxyUsername:            "u",
		LimitSyncUploadBandwidth: true,
		SyncUploadCapMbps:        10,
		SyncSmallPutConcurrency:  16,
		SyncMediumPutConcurrency: 8,
		SyncLargePutConcurrency:  2,
	}
	if err := SaveAppPreferences(path, in); err != nil {
		t.Fatal(err)
	}
	got := LoadAppPreferences(path)
	if got.ProxyMode != ProxyModeCustom || got.ProxyHost != "127.0.0.1" || got.ProxyPort != 3128 {
		t.Fatalf("proxy: %+v", got)
	}
	if !got.LimitSyncUploadBandwidth || got.SyncUploadCapMbps != 10 {
		t.Fatalf("bw: %+v", got)
	}
	if got.SyncSmallPutConcurrency != 16 || got.SyncLargePutConcurrency != 2 {
		t.Fatalf("workers: %+v", got)
	}
	raw, _ := os.ReadFile(path)
	if strings.Contains(string(raw), "proxyPassword") || strings.Contains(string(raw), "CRYPTOMAKO") {
		t.Fatalf("secrets leaked into JSON: %s", raw)
	}
}

func TestDescribeAndApplyProxy(t *testing.T) {
	if DescribeProxy(AppPreferences{ProxyMode: ProxyModeSystem}) != "system" {
		t.Fatal("system")
	}
	if DescribeProxy(AppPreferences{ProxyMode: ProxyModeDirect}) != "direct" {
		t.Fatal("direct")
	}
	if DescribeProxy(AppPreferences{ProxyMode: ProxyModeCustom, ProxyHost: "proxy.example", ProxyPort: 3128}) != "custom:proxy.example:3128" {
		t.Fatal("custom")
	}
	if DescribeProxy(AppPreferences{ProxyMode: ProxyModeCustom, ProxyHost: "", ProxyPort: 0}) != "custom:invalid" {
		t.Fatal("invalid custom")
	}

	tr := http.DefaultTransport.(*http.Transport).Clone()
	ApplyProxy(tr, AppPreferences{ProxyMode: ProxyModeDirect}, "")
	u, err := tr.Proxy(&http.Request{URL: mustURL(t, "https://example.com")})
	if err != nil || u != nil {
		t.Fatalf("direct proxy = %v err=%v", u, err)
	}

	tr2 := http.DefaultTransport.(*http.Transport).Clone()
	ApplyProxy(tr2, AppPreferences{
		ProxyMode:     ProxyModeCustom,
		ProxyHost:     "127.0.0.1",
		ProxyPort:     8080,
		ProxyUsername: "u",
	}, "p")
	u2, err := tr2.Proxy(&http.Request{URL: mustURL(t, "https://example.com")})
	if err != nil || u2 == nil {
		t.Fatalf("custom proxy err=%v u=%v", err, u2)
	}
	if u2.Host != "127.0.0.1:8080" {
		t.Fatalf("host = %q", u2.Host)
	}
	if u2.User == nil || u2.User.Username() != "u" {
		t.Fatalf("user = %v", u2.User)
	}
	pw, _ := u2.User.Password()
	if pw != "p" {
		t.Fatalf("password = %q", pw)
	}

	client := NewHTTPClient(DefaultAppPreferences())
	if client == nil || client.Transport == nil {
		t.Fatal("NewHTTPClient")
	}
}

func TestBandwidthLimiterPaces(t *testing.T) {
	// 8000 bytes/sec → 4000 bytes should take ~0.5s after bursting the 1s bucket.
	lim := NewUploadBandwidthLimiter(8000)
	lim.Acquire(8000) // consume burst
	start := time.Now()
	lim.Acquire(4000)
	elapsed := time.Since(start)
	if elapsed < 400*time.Millisecond {
		t.Fatalf("expected pacing, elapsed=%v", elapsed)
	}
	if UploadBandwidthLimiterFromPreferences(DefaultAppPreferences()) != nil {
		t.Fatal("default unlimited")
	}
	on := DefaultAppPreferences()
	on.LimitSyncUploadBandwidth = true
	on.SyncUploadCapMbps = 50
	if UploadBandwidthLimiterFromPreferences(on) == nil {
		t.Fatal("expected limiter")
	}
}

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return u
}
