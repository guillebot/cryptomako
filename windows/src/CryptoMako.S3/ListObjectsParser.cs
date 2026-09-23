using System.Xml.Linq;
using CryptoMako.Vault;

namespace CryptoMako.S3;

internal static class ListObjectsParser
{
    public sealed class Result
    {
        public PrefixListing Listing { get; init; } = new();
        public string? NextContinuationToken { get; init; }
        public bool IsTruncated { get; init; }
    }

    public static Result Parse(byte[] xmlBytes)
    {
        var doc = XDocument.Load(new MemoryStream(xmlBytes));
        XNamespace ns = doc.Root?.Name.Namespace ?? "";
        var objects = new List<ListedObject>();
        var prefixes = new List<string>();

        foreach (var contents in doc.Descendants(ns + "Contents"))
        {
            var key = contents.Element(ns + "Key")?.Value ?? "";
            if (string.IsNullOrEmpty(key)) continue;
            var size = long.TryParse(contents.Element(ns + "Size")?.Value, out var s) ? s : 0;
            var eTag = contents.Element(ns + "ETag")?.Value?.Trim('"');
            objects.Add(new ListedObject { Key = key, Size = size, ETag = eTag });
        }

        foreach (var cp in doc.Descendants(ns + "CommonPrefixes"))
        {
            var prefix = cp.Element(ns + "Prefix")?.Value;
            if (!string.IsNullOrEmpty(prefix))
                prefixes.Add(prefix);
        }

        var truncated = string.Equals(doc.Root?.Element(ns + "IsTruncated")?.Value, "true", StringComparison.OrdinalIgnoreCase);
        var next = doc.Root?.Element(ns + "NextContinuationToken")?.Value;
        if (string.IsNullOrEmpty(next)) next = null;

        return new Result
        {
            Listing = new PrefixListing { Objects = objects, CommonPrefixes = prefixes },
            NextContinuationToken = next,
            IsTruncated = truncated,
        };
    }
}
