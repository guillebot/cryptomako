namespace CryptoMako.Vault;

/// <summary>
/// Blob store used by the vault layer. Durable success = remote put/delete ACK on S3;
/// <see cref="DirectoryObjectStore"/> is for --local / tests only.
/// </summary>
public interface IObjectStore
{
    Task<byte[]> GetObjectAsync(string key, CancellationToken ct = default);
    Task GetObjectAsync(string key, string destinationPath, CancellationToken ct = default);
    Task<ListedObject> HeadObjectAsync(string key, CancellationToken ct = default);
    Task<PrefixListing> ListImmediateAsync(string prefix, CancellationToken ct = default);
    Task PutObjectAsync(string key, byte[] data, CancellationToken ct = default);
    Task PutObjectAsync(string key, string sourceFilePath, CancellationToken ct = default);
    Task DeleteObjectAsync(string key, CancellationToken ct = default);
}

public sealed class PrefixListing
{
    public List<ListedObject> Objects { get; init; } = new();
    public List<string> CommonPrefixes { get; init; } = new();
}

public sealed class ListedObject
{
    public required string Key { get; init; }
    public long Size { get; init; }
    public string? ETag { get; init; }
}

public class ObjectStoreException : Exception
{
    public ObjectStoreException(string message) : base(message) { }
    public ObjectStoreException(string message, Exception inner) : base(message, inner) { }
}

public sealed class ObjectNotFoundException : ObjectStoreException
{
    public string Key { get; }
    public ObjectNotFoundException(string key) : base($"object not found: {key}") => Key = key;
}
