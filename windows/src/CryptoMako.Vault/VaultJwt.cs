using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

internal static class VaultJwt
{
    public sealed class Payload
    {
        [JsonPropertyName("format")]
        public int Format { get; set; }

        [JsonPropertyName("cipherCombo")]
        public string? CipherCombo { get; set; }

        [JsonPropertyName("shorteningThreshold")]
        public int ShorteningThreshold { get; set; }

        [JsonPropertyName("jti")]
        public string? Jti { get; set; }
    }

    public static Payload Verify(string token, byte[] rawKey)
    {
        var parts = token.Split('.');
        if (parts.Length != 3)
            throw new InvalidDataException("vault.cryptomator is not a JWT");

        var headerJson = Encoding.UTF8.GetString(EncodingUtil.Base64Url(parts[0]));
        using var headerDoc = JsonDocument.Parse(headerJson);
        var alg = headerDoc.RootElement.TryGetProperty("alg", out var algEl)
            ? algEl.GetString()?.ToUpperInvariant()
            : null;
        if (alg != "HS256")
            throw new NotSupportedException($"Unsupported JWT alg: {alg}");

        var signingInput = Encoding.UTF8.GetBytes(parts[0] + "." + parts[1]);
        var expected = HMACSHA256.HashData(rawKey, signingInput);
        try
        {
            var actual = EncodingUtil.Base64Url(parts[2]);
            if (!CryptographicOperations.FixedTimeEquals(expected, actual))
                throw new UnauthorizedAccessException("Invalid vault.cryptomator JWT signature.");

            var payloadJson = Encoding.UTF8.GetString(EncodingUtil.Base64Url(parts[1]));
            return JsonSerializer.Deserialize<Payload>(payloadJson)
                ?? throw new InvalidDataException("empty vault.cryptomator payload");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(expected);
            CryptographicOperations.ZeroMemory(signingInput);
        }
    }
}
