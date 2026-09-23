using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CryptoMako.Vault;

public sealed class VaultMetadata
{
    public required int Format { get; init; }
    public required string CipherCombo { get; init; }
    public int ShorteningThreshold { get; init; }
    public string? Jti { get; init; }

    public static VaultMetadata ReadLocal(string vaultDirectory)
    {
        var path = Path.Combine(vaultDirectory, "vault.cryptomator");
        if (!File.Exists(path))
            throw new FileNotFoundException("vault.cryptomator not found", path);

        var jwt = File.ReadAllText(path).Trim();
        var parts = jwt.Split('.');
        if (parts.Length < 2)
            throw new InvalidDataException("vault.cryptomator is not a JWT");

        var json = Encoding.UTF8.GetString(Base64UrlDecode(parts[1]));
        var payload = JsonSerializer.Deserialize<VaultJwtPayload>(json)
            ?? throw new InvalidDataException("empty vault.cryptomator payload");

        if (payload.Format != 8)
            throw new NotSupportedException($"Only Cryptomator format 8 is supported (got {payload.Format})");

        return new VaultMetadata
        {
            Format = payload.Format,
            CipherCombo = payload.CipherCombo ?? "unknown",
            ShorteningThreshold = payload.ShorteningThreshold,
            Jti = payload.Jti,
        };
    }

    private static byte[] Base64UrlDecode(string input)
    {
        var s = input.Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4)
        {
            case 2: s += "=="; break;
            case 3: s += "="; break;
        }
        return Convert.FromBase64String(s);
    }

    private sealed class VaultJwtPayload
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
}
