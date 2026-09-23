using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using CryptoMako.Vault;

namespace CryptoMako.S3;

public sealed class S3Settings
{
    public required Uri Endpoint { get; init; }
    public required string Region { get; init; }
    public required string Bucket { get; init; }
    public required string AccessKey { get; init; }
    public required string SecretKey { get; init; }
    /// <summary>True = /bucket/key path-style (MinIO); false = virtual-hosted.</summary>
    public bool PathStyle { get; init; } = true;

    public static S3Settings From(
        string endpoint,
        string region,
        string bucket,
        string accessKey,
        string secretKey,
        bool pathStyle = true)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri))
            throw new ArgumentException("Invalid S3 endpoint URL.", nameof(endpoint));
        if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("S3 endpoint must be HTTPS.", nameof(endpoint));
        if (string.IsNullOrWhiteSpace(bucket))
            throw new ArgumentException("Bucket required.", nameof(bucket));
        if (string.IsNullOrWhiteSpace(accessKey))
            throw new ArgumentException("Access key required.", nameof(accessKey));
        if (string.IsNullOrWhiteSpace(secretKey))
            throw new ArgumentException("Secret key required.", nameof(secretKey));

        return new S3Settings
        {
            Endpoint = uri,
            Region = string.IsNullOrWhiteSpace(region) ? "us-east-1" : region,
            Bucket = bucket,
            AccessKey = accessKey,
            SecretKey = secretKey,
            PathStyle = pathStyle,
        };
    }
}

/// <summary>
/// SigV4 HTTPS S3 client. Fail-closed: put/delete succeed only on HTTP 2xx.
/// </summary>
public sealed class S3ObjectStore : IObjectStore, IDisposable
{
    public static HttpClient CreateHttpClient(CryptoMako.Vault.AppPreferences? prefs = null, string? proxyPassword = null)
    {
        prefs ??= new CryptoMako.Vault.AppPreferences();
        return CryptoMako.Vault.ProxyHttp.CreateClient(prefs, proxyPassword);
    }

    private readonly S3Settings _settings;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;

    public S3ObjectStore(S3Settings settings, HttpClient? httpClient = null)
    {
        _settings = settings;
        if (httpClient is null)
        {
            _http = new HttpClient();
            _ownsHttp = true;
        }
        else
        {
            _http = httpClient;
            _ownsHttp = false;
        }
    }

    public async Task<byte[]> GetObjectAsync(string key, CancellationToken ct = default)
    {
        using var req = BuildSignedRequest(HttpMethod.Get, key, query: null);
        using var resp = await _http.SendAsync(req, ct);
        await EnsureSuccessAsync(resp, key, ct);
        return await resp.Content.ReadAsByteArrayAsync(ct);
    }

    public async Task GetObjectAsync(string key, string destinationPath, CancellationToken ct = default)
    {
        var data = await GetObjectAsync(key, ct);
        var dir = Path.GetDirectoryName(destinationPath);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        await File.WriteAllBytesAsync(destinationPath, data, ct);
    }

    public async Task<ListedObject> HeadObjectAsync(string key, CancellationToken ct = default)
    {
        using var req = BuildSignedRequest(HttpMethod.Head, key, query: null);
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (resp.StatusCode == HttpStatusCode.NotFound)
            throw new ObjectNotFoundException(key);
        await EnsureSuccessAsync(resp, key, ct);
        var len = resp.Content.Headers.ContentLength ?? 0;
        var eTag = resp.Headers.ETag?.Tag?.Trim('"')
            ?? (resp.Headers.TryGetValues("ETag", out var vals) ? vals.FirstOrDefault()?.Trim('"') : null);
        return new ListedObject { Key = key, Size = len, ETag = eTag };
    }

    public async Task<PrefixListing> ListImmediateAsync(string prefix, CancellationToken ct = default)
    {
        var objects = new List<ListedObject>();
        var common = new List<string>();
        string? token = null;

        do
        {
            var query = new List<KeyValuePair<string, string>>
            {
                new("list-type", "2"),
                new("delimiter", "/"),
                new("prefix", prefix),
            };
            if (token is not null)
                query.Add(new("continuation-token", token));

            using var req = BuildSignedRequest(HttpMethod.Get, key: "", query);
            using var resp = await _http.SendAsync(req, ct);
            await EnsureSuccessAsync(resp, prefix, ct);
            var body = await resp.Content.ReadAsByteArrayAsync(ct);
            var parsed = ListObjectsParser.Parse(body);
            objects.AddRange(parsed.Listing.Objects);
            common.AddRange(parsed.Listing.CommonPrefixes);
            token = parsed.IsTruncated ? parsed.NextContinuationToken : null;
        } while (token is not null);

        return new PrefixListing { Objects = objects, CommonPrefixes = common };
    }

    public async Task PutObjectAsync(string key, byte[] data, CancellationToken ct = default)
    {
        var hash = SigV4.Hex(SHA256.HashData(data));
        using var req = BuildSignedRequest(HttpMethod.Put, key, query: null, payloadHash: hash);
        req.Content = new ByteArrayContent(data);
        req.Content.Headers.ContentLength = data.Length;
        using var resp = await _http.SendAsync(req, ct);
        await EnsureSuccessAsync(resp, key, ct);
    }

    public async Task PutObjectAsync(string key, string sourceFilePath, CancellationToken ct = default)
    {
        // UNSIGNED-PAYLOAD streaming put (no full-file SHA256).
        var info = new FileInfo(sourceFilePath);
        await using var stream = File.OpenRead(sourceFilePath);
        using var req = BuildSignedRequest(HttpMethod.Put, key, query: null, payloadHash: "UNSIGNED-PAYLOAD");
        req.Content = new StreamContent(stream);
        req.Content.Headers.ContentLength = info.Length;
        using var resp = await _http.SendAsync(req, ct);
        await EnsureSuccessAsync(resp, key, ct);
    }

    public async Task DeleteObjectAsync(string key, CancellationToken ct = default)
    {
        using var req = BuildSignedRequest(HttpMethod.Delete, key, query: null);
        using var resp = await _http.SendAsync(req, ct);
        await EnsureSuccessAsync(resp, key, ct);
    }

    private HttpRequestMessage BuildSignedRequest(
        HttpMethod method,
        string key,
        List<KeyValuePair<string, string>>? query,
        string payloadHash = SigV4.EmptyPayloadSha256,
        DateTimeOffset? now = null)
    {
        var uri = BuildUri(key, query);
        var headers = SigV4.Sign(
            method,
            uri,
            new SigV4.Credentials
            {
                AccessKey = _settings.AccessKey,
                SecretKey = _settings.SecretKey,
                Region = _settings.Region,
            },
            payloadHash,
            now);

        var req = new HttpRequestMessage(method, uri);
        foreach (var (name, value) in headers)
        {
            if (name.Equals("host", StringComparison.OrdinalIgnoreCase))
                continue; // HttpClient sets Host from URI
            req.Headers.TryAddWithoutValidation(name, value);
        }
        return req;
    }

    private Uri BuildUri(string key, List<KeyValuePair<string, string>>? query)
    {
        var builder = new UriBuilder(_settings.Endpoint);
        if (_settings.PathStyle)
        {
            var path = "/" + _settings.Bucket + (string.IsNullOrEmpty(key) ? "/" : "/" + key);
            builder.Path = path;
        }
        else
        {
            builder.Host = _settings.Bucket + "." + _settings.Endpoint.Host;
            builder.Path = string.IsNullOrEmpty(key) ? "/" : "/" + key;
        }

        if (query is { Count: > 0 })
            builder.Query = SigV4.CanonicalQueryString(query);

        return builder.Uri;
    }

    private static async Task EnsureSuccessAsync(HttpResponseMessage resp, string key, CancellationToken ct)
    {
        if ((int)resp.StatusCode is >= 200 and <= 299)
            return;
        if (resp.StatusCode == HttpStatusCode.NotFound)
            throw new ObjectNotFoundException(key);

        var detail = "";
        try { detail = await resp.Content.ReadAsStringAsync(ct); }
        catch { /* ignore */ }
        detail = detail.Replace('\n', ' ').Replace('\r', ' ');
        if (detail.Length > 200) detail = detail[..200];
        throw new ObjectStoreException($"HTTP {(int)resp.StatusCode} for {key} {detail}".Trim());
    }

    public void Dispose()
    {
        if (_ownsHttp)
            _http.Dispose();
    }
}

/// <summary>Back-compat alias used by early scaffold docs.</summary>
public sealed class S3Client
{
    private readonly S3ObjectStore _store;

    public Uri Endpoint => _settings.Endpoint;
    public string Region => _settings.Region;
    public string Bucket => _settings.Bucket;
    private readonly S3Settings _settings;

    public S3Client(string endpoint, string region, string bucket, string accessKey, string secretKey, bool pathStyle = true)
    {
        _settings = S3Settings.From(endpoint, region, bucket, accessKey, secretKey, pathStyle);
        _store = new S3ObjectStore(_settings);
    }

    public S3ObjectStore Store => _store;

    public Task EnsureReachableAsync(CancellationToken ct = default)
        => _store.ListImmediateAsync("", ct);
}
