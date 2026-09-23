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
        };
        ApplyProxy(handler, prefs, proxyPassword);
        return handler;
    }

    public static HttpClient CreateClient(AppPreferences prefs, string? proxyPassword = null) =>
        new(CreateHandler(prefs, proxyPassword), disposeHandler: true);

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
                handler.UseProxy = true;
                handler.Proxy = null; // HttpClient uses system proxy
                break;
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
}
