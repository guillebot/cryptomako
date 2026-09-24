using System.Net;

namespace CryptoMako.Vault;

/// <summary>Maps <see cref="AppPreferences"/> proxyMode onto an <see cref="HttpMessageHandler"/>.</summary>
public static class ProxyHttp
{
    public static HttpMessageHandler CreateHandler(AppPreferences prefs, string? proxyPassword = null)
    {
        var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(30),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        ApplyProxy(handler, prefs, proxyPassword);
        return handler;
    }

    public static HttpClient CreateClient(AppPreferences prefs, string? proxyPassword = null)
    {
        return new HttpClient(CreateHandler(prefs, proxyPassword), disposeHandler: true)
        {
            // Fail hung Sync/FETCH rather than waiting forever.
            Timeout = TimeSpan.FromSeconds(100),
        };
    }

    public static void ApplyProxy(SocketsHttpHandler handler, AppPreferences prefs, string? proxyPassword = null)
    {
        var mode = (prefs.ProxyMode ?? "system").Trim().ToLowerInvariant();
        switch (mode)
        {
            case "direct":
                handler.UseProxy = false;
                handler.Proxy = null;
                break;
            case "custom":
            {
                var host = (prefs.ProxyHost ?? "").Trim();
                if (string.IsNullOrEmpty(host) || prefs.ProxyPort <= 0 || prefs.ProxyPort > 65535)
                {
                    // Invalid custom → leave system default (fail soft for UI; Sync still needs HTTPS).
                    handler.UseProxy = true;
                    handler.Proxy = null;
                    break;
                }
                var proxy = new WebProxy(host, prefs.ProxyPort);
                var user = (prefs.ProxyUsername ?? "").Trim();
                if (!string.IsNullOrEmpty(user))
                {
                    proxy.Credentials = new NetworkCredential(user, proxyPassword ?? "");
                }
                handler.UseProxy = true;
                handler.Proxy = proxy;
                break;
            }
            default: // system
            {
                // Keep system proxy, but never tunnel loopback (local MinIO) through it —
                // system proxies often black-hole 127.0.0.1 and stall Sync on the last file.
                handler.UseProxy = true;
                handler.Proxy = new BypassLoopbackProxy(HttpClient.DefaultProxy);
                break;
            }
        }
    }

    /// <summary>Test helper: describe effective proxy mode after apply.</summary>
    public static string Describe(AppPreferences prefs)
    {
        var mode = (prefs.ProxyMode ?? "system").Trim().ToLowerInvariant();
        return mode switch
        {
            "direct" => "direct",
            "custom" when !string.IsNullOrWhiteSpace(prefs.ProxyHost) && prefs.ProxyPort is > 0 and <= 65535
                => $"custom:{prefs.ProxyHost}:{prefs.ProxyPort}",
            "custom" => "custom:invalid",
            _ => "system",
        };
    }

    /// <summary>Wraps the system proxy but always bypasses loopback hosts.</summary>
    private sealed class BypassLoopbackProxy : IWebProxy
    {
        private readonly IWebProxy _inner;

        public BypassLoopbackProxy(IWebProxy? inner) =>
            _inner = inner ?? new WebProxy { BypassProxyOnLocal = true };

        public ICredentials? Credentials
        {
            get => _inner.Credentials;
            set => _inner.Credentials = value;
        }

        public Uri? GetProxy(Uri destination) =>
            IsLoopback(destination) ? destination : _inner.GetProxy(destination);

        public bool IsBypassed(Uri host) =>
            IsLoopback(host) || _inner.IsBypassed(host);

        private static bool IsLoopback(Uri host) =>
            host.IsLoopback
            || string.Equals(host.Host, "localhost", StringComparison.OrdinalIgnoreCase)
            || host.Host is "127.0.0.1" or "::1" or "[::1]";
    }

}
