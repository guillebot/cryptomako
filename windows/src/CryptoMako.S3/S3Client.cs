namespace CryptoMako.S3;

/// <summary>
/// SigV4 HTTPS S3 client stub. Plain HTTP is rejected. Fail-closed: success only after remote put/delete ACK.
/// </summary>
public sealed class S3Client
{
    public Uri Endpoint { get; }
    public string Region { get; }
    public string Bucket { get; }

    public S3Client(string endpoint, string region, string bucket)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("S3 endpoint must be HTTPS.", nameof(endpoint));
        Endpoint = uri;
        Region = region;
        Bucket = bucket;
    }

    public Task EnsureReachableAsync(CancellationToken ct = default)
        => throw new NotImplementedException("SigV4 ListBuckets/HeadBucket not wired yet.");
}
