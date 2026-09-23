package config

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ApplyProxy maps proxyMode onto an http.Transport (macOS applyProxy / Windows ProxyHttp).
//
//   - system: honor HTTP_PROXY / HTTPS_PROXY / NO_PROXY via ProxyFromEnvironment
//   - direct: bypass proxies
//   - custom: HTTP proxy at proxyHost:proxyPort; username from JSON, password from env
//
// Invalid custom (empty host / bad port) fails soft → system env proxy (same as Windows).
func ApplyProxy(transport *http.Transport, prefs AppPreferences, proxyPassword string) {
	if transport == nil {
		return
	}
	mode := strings.ToLower(strings.TrimSpace(prefs.ProxyMode))
	switch mode {
	case ProxyModeDirect:
		transport.Proxy = func(*http.Request) (*url.URL, error) { return nil, nil }
	case ProxyModeCustom:
		u, ok := customProxyURL(prefs, proxyPassword)
		if !ok {
			transport.Proxy = http.ProxyFromEnvironment
			return
		}
		transport.Proxy = http.ProxyURL(u)
	default: // system + unknown
		transport.Proxy = http.ProxyFromEnvironment
	}
}

func customProxyURL(prefs AppPreferences, proxyPassword string) (*url.URL, bool) {
	host := strings.TrimSpace(prefs.ProxyHost)
	if host == "" || prefs.ProxyPort <= 0 || prefs.ProxyPort > 65535 {
		return nil, false
	}
	u := &url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(host, strconv.Itoa(prefs.ProxyPort)),
	}
	user := strings.TrimSpace(prefs.ProxyUsername)
	if user != "" {
		if proxyPassword != "" {
			u.User = url.UserPassword(user, proxyPassword)
		} else {
			u.User = url.User(user)
		}
	}
	return u, true
}

// DescribeProxy is a test helper describing the effective proxy mode.
func DescribeProxy(prefs AppPreferences) string {
	mode := strings.ToLower(strings.TrimSpace(prefs.ProxyMode))
	switch mode {
	case ProxyModeDirect:
		return ProxyModeDirect
	case ProxyModeCustom:
		host := strings.TrimSpace(prefs.ProxyHost)
		if host != "" && prefs.ProxyPort > 0 && prefs.ProxyPort <= 65535 {
			return fmt.Sprintf("custom:%s:%d", host, prefs.ProxyPort)
		}
		return "custom:invalid"
	default:
		return ProxyModeSystem
	}
}

// NewHTTPClient builds an HTTPS-capable client with prefs-applied proxy.
// Used by the S3 SigV4 client (10m timeout, no auto-follow redirects).
func NewHTTPClient(prefs AppPreferences) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	ApplyProxy(transport, prefs, ProxyPassword())
	return &http.Client{
		Transport: transport,
		Timeout:   10 * time.Minute,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}
