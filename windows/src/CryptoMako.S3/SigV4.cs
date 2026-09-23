using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace CryptoMako.S3;

/// <summary>AWS Signature Version 4 for S3 (mirrors Sources/CryptoMakoS3/SigV4.swift).</summary>
public static class SigV4
{
    public const string EmptyPayloadSha256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    public sealed class Credentials
    {
        public required string AccessKey { get; init; }
        public required string SecretKey { get; init; }
        public required string Region { get; init; }
        public string Service { get; init; } = "s3";
    }

    /// <summary>Returns headers to attach (host, x-amz-date, x-amz-content-sha256, Authorization).</summary>
    public static Dictionary<string, string> Sign(
        HttpMethod method,
        Uri url,
        Credentials credentials,
        string payloadHash = EmptyPayloadSha256,
        DateTimeOffset? now = null)
    {
        var instant = now ?? DateTimeOffset.UtcNow;
        var amzDate = instant.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var dateStamp = amzDate[..8];

        var hostHeader = url.IsDefaultPort
            ? url.Host
            : $"{url.Host}:{url.Port}";

        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["host"] = hostHeader,
            ["x-amz-date"] = amzDate,
            ["x-amz-content-sha256"] = payloadHash,
        };

        var canonicalUri = CanonicalPath(url);
        var canonicalQuery = CanonicalQueryString(url);
        var sortedKeys = headers.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        var canonicalHeaders = string.Concat(sortedKeys.Select(k => $"{k}:{headers[k].Trim()}\n"));
        var signedHeaders = string.Join(';', sortedKeys);

        var canonicalRequest = string.Join('\n',
            method.Method,
            canonicalUri,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash);

        var scope = $"{dateStamp}/{credentials.Region}/{credentials.Service}/aws4_request";
        var stringToSign = string.Join('\n',
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest))));

        var signingKey = DerivedKey(credentials.SecretKey, dateStamp, credentials.Region, credentials.Service);
        try
        {
            var signature = Hex(HmacSha256(signingKey, Encoding.UTF8.GetBytes(stringToSign)));

            headers["Authorization"] =
                "AWS4-HMAC-SHA256 " +
                $"Credential={credentials.AccessKey}/{scope}, " +
                $"SignedHeaders={signedHeaders}, " +
                $"Signature={signature}";

            return headers;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(signingKey);
        }
    }

    public static string CanonicalPath(Uri url)
    {
        // Use AbsolutePath so trailing slash is preserved (ListObjectsV2 on /bucket/).
        var raw = url.AbsolutePath;
        if (string.IsNullOrEmpty(raw))
            raw = "/";
        var decoded = Uri.UnescapeDataString(raw);
        return UriEncode(decoded, encodeSlash: false);
    }

    public static string CanonicalQueryString(Uri url)
    {
        var query = url.Query;
        if (string.IsNullOrEmpty(query) || query == "?")
            return "";
        var items = ParseQuery(query.TrimStart('?'));
        return CanonicalQueryString(items);
    }

    public static string CanonicalQueryString(IEnumerable<KeyValuePair<string, string>> items)
    {
        var pairs = items
            .Select(kv => (
                Name: UriEncode(kv.Key, encodeSlash: true),
                Value: UriEncode(kv.Value ?? "", encodeSlash: true)))
            .OrderBy(p => p.Name, StringComparer.Ordinal)
            .ThenBy(p => p.Value, StringComparer.Ordinal)
            .Select(p => p.Name + "=" + p.Value);
        return string.Join('&', pairs);
    }

    public static string UriEncode(string value, bool encodeSlash)
    {
        var sb = new StringBuilder(value.Length * 2);
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            if ((b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9')
                || b is (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~')
            {
                sb.Append((char)b);
            }
            else if (b == (byte)'/' && !encodeSlash)
            {
                sb.Append('/');
            }
            else
            {
                sb.Append('%');
                sb.Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return sb.ToString();
    }

    public static string Hex(ReadOnlySpan<byte> bytes)
    {
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
            sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    public static byte[] DerivedKey(string secret, string dateStamp, string region, string service)
    {
        // Zero each intermediate HMAC key; caller must ZeroMemory the returned signing key.
        var key = Encoding.UTF8.GetBytes("AWS4" + secret);
        try
        {
            var next = HmacSha256(key, Encoding.UTF8.GetBytes(dateStamp));
            CryptographicOperations.ZeroMemory(key);
            key = next;
            next = HmacSha256(key, Encoding.UTF8.GetBytes(region));
            CryptographicOperations.ZeroMemory(key);
            key = next;
            next = HmacSha256(key, Encoding.UTF8.GetBytes(service));
            CryptographicOperations.ZeroMemory(key);
            key = next;
            next = HmacSha256(key, Encoding.UTF8.GetBytes("aws4_request"));
            CryptographicOperations.ZeroMemory(key);
            key = next;
            return key;
        }
        catch
        {
            CryptographicOperations.ZeroMemory(key);
            throw;
        }
    }

    private static byte[] HmacSha256(byte[] key, byte[] data)
    {
        using var hmac = new HMACSHA256(key);
        return hmac.ComputeHash(data);
    }

    private static List<KeyValuePair<string, string>> ParseQuery(string query)
    {
        var list = new List<KeyValuePair<string, string>>();
        foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            if (eq < 0)
                list.Add(new(Uri.UnescapeDataString(part), ""));
            else
                list.Add(new(
                    Uri.UnescapeDataString(part[..eq]),
                    Uri.UnescapeDataString(part[(eq + 1)..])));
        }
        return list;
    }
}
