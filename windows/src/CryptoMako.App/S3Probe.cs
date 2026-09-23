using CryptoMako.S3;
using CryptoMako.Vault;

namespace CryptoMako.App;

public enum ProbeLamp { Unknown, Ok, Fail, Skip }

public sealed class S3ProbeResult
{
    public ProbeLamp Dns { get; init; }
    public ProbeLamp Tcp { get; init; }
    public ProbeLamp Https { get; init; }
    public ProbeLamp List { get; init; }
    public string Detail { get; init; } = "";
}

public static class S3Probe
{
    public static async Task<S3ProbeResult> ProbeAsync(
        VaultSettings settings,
        string? secretKey,
        AppPreferences? prefs = null,
        string? proxyPassword = null,
        CancellationToken ct = default)
    {
        if (settings.IsLocal)
        {
            return new S3ProbeResult
            {
                Dns = ProbeLamp.Skip,
                Tcp = ProbeLamp.Skip,
                Https = ProbeLamp.Skip,
                List = ProbeLamp.Skip,
                Detail = "local mode",
            };
        }

        prefs ??= new AppPreferences();
        if (string.IsNullOrWhiteSpace(settings.Endpoint)
            || string.IsNullOrWhiteSpace(settings.Bucket)
            || string.IsNullOrWhiteSpace(settings.AccessKey)
            || string.IsNullOrEmpty(secretKey))
        {
            return new S3ProbeResult
            {
                Dns = ProbeLamp.Fail,
                Tcp = ProbeLamp.Fail,
                Https = ProbeLamp.Fail,
                List = ProbeLamp.Fail,
                Detail = "incomplete S3 settings or missing secret",
            };
        }

        Uri endpoint;
        try { endpoint = new Uri(settings.Endpoint); }
        catch
        {
            return new S3ProbeResult { Dns = ProbeLamp.Fail, Detail = "bad endpoint URL" };
        }

        if (!string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            return new S3ProbeResult { Dns = ProbeLamp.Fail, Https = ProbeLamp.Fail, Detail = "endpoint must be https" };

        var dns = ProbeLamp.Unknown;
        var tcp = ProbeLamp.Unknown;
        try
        {
            var addresses = await System.Net.Dns.GetHostAddressesAsync(endpoint.Host, ct);
            dns = addresses.Length > 0 ? ProbeLamp.Ok : ProbeLamp.Fail;
        }
        catch (Exception ex)
        {
            return new S3ProbeResult { Dns = ProbeLamp.Fail, Detail = ex.Message };
        }

        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            var port = endpoint.IsDefaultPort ? 443 : endpoint.Port;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(5));
            await client.ConnectAsync(endpoint.Host, port, cts.Token);
            tcp = ProbeLamp.Ok;
        }
        catch (Exception ex)
        {
            return new S3ProbeResult { Dns = dns, Tcp = ProbeLamp.Fail, Detail = ex.Message };
        }

        try
        {
            var s3 = S3Settings.From(settings.Endpoint, settings.Region, settings.Bucket, settings.AccessKey, secretKey, settings.PathStyle);
            using var http = S3ObjectStore.CreateHttpClient(prefs, proxyPassword);
            using var store = new S3ObjectStore(s3, http);
            var prefix = settings.NormalizedPrefix;
            _ = await store.ListImmediateAsync(prefix, ct);
            return new S3ProbeResult { Dns = dns, Tcp = tcp, Https = ProbeLamp.Ok, List = ProbeLamp.Ok, Detail = "ok" };
        }
        catch (Exception ex)
        {
            return new S3ProbeResult
            {
                Dns = dns,
                Tcp = tcp,
                Https = ProbeLamp.Fail,
                List = ProbeLamp.Fail,
                Detail = ex.Message.Replace('\n', ' '),
            };
        }
    }
}
