using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Crypto.Generators;

namespace CryptoMako.Vault;

public sealed class MasterkeyFile
{
    public int Version { get; }
    public byte[] ScryptSalt { get; }
    public int ScryptCostParam { get; }
    public int ScryptBlockSize { get; }
    public byte[] PrimaryMasterKeyWrapped { get; }
    public byte[] HmacMasterKeyWrapped { get; }
    public byte[] VersionMac { get; }

    private MasterkeyFile(
        int version,
        byte[] scryptSalt,
        int scryptCostParam,
        int scryptBlockSize,
        byte[] primaryMasterKeyWrapped,
        byte[] hmacMasterKeyWrapped,
        byte[] versionMac)
    {
        Version = version;
        ScryptSalt = scryptSalt;
        ScryptCostParam = scryptCostParam;
        ScryptBlockSize = scryptBlockSize;
        PrimaryMasterKeyWrapped = primaryMasterKeyWrapped;
        HmacMasterKeyWrapped = hmacMasterKeyWrapped;
        VersionMac = versionMac;
    }

    public static MasterkeyFile Load(string path)
    {
        var json = File.ReadAllText(path);
        return Parse(json);
    }

    public static MasterkeyFile Parse(string json)
    {
        var dto = JsonSerializer.Deserialize<Dto>(json)
            ?? throw new InvalidDataException("empty masterkey.cryptomator");
        if (string.IsNullOrEmpty(dto.ScryptSalt)
            || string.IsNullOrEmpty(dto.PrimaryMasterKey)
            || string.IsNullOrEmpty(dto.HmacMasterKey)
            || string.IsNullOrEmpty(dto.VersionMac))
            throw new InvalidDataException("malformed masterkey.cryptomator");

        return new MasterkeyFile(
            dto.Version,
            EncodingUtil.Base64(dto.ScryptSalt),
            dto.ScryptCostParam,
            dto.ScryptBlockSize,
            EncodingUtil.Base64(dto.PrimaryMasterKey),
            EncodingUtil.Base64(dto.HmacMasterKey),
            EncodingUtil.Base64(dto.VersionMac));
    }

    public Masterkey Unlock(string passphrase)
    {
        var pw = Encoding.UTF8.GetBytes(passphrase.Normalize(NormalizationForm.FormC));
        try
        {
            var kek = SCrypt.Generate(pw, ScryptSalt, ScryptCostParam, ScryptBlockSize, 1, 32);
            try
            {
                byte[] aesKey;
                byte[] macKey;
                try
                {
                    aesKey = AesKeyWrap.Unwrap(kek, PrimaryMasterKeyWrapped);
                    macKey = AesKeyWrap.Unwrap(kek, HmacMasterKeyWrapped);
                }
                catch (CryptographicException)
                {
                    throw new UnauthorizedAccessException("Invalid vault password.");
                }

                VerifyVersionMac(macKey);
                return new Masterkey(aesKey, macKey);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(kek);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pw);
        }
    }

    private void VerifyVersionMac(byte[] macKey)
    {
        Span<byte> versionBe = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(versionBe, (uint)Version);
        var calculated = HMACSHA256.HashData(macKey, versionBe);
        if (!CryptographicOperations.FixedTimeEquals(calculated, VersionMac))
            throw new InvalidDataException("incorrect version or versionMac");
    }

    private sealed class Dto
    {
        [JsonPropertyName("version")]
        public int Version { get; set; }

        [JsonPropertyName("scryptSalt")]
        public string? ScryptSalt { get; set; }

        [JsonPropertyName("scryptCostParam")]
        public int ScryptCostParam { get; set; }

        [JsonPropertyName("scryptBlockSize")]
        public int ScryptBlockSize { get; set; }

        [JsonPropertyName("primaryMasterKey")]
        public string? PrimaryMasterKey { get; set; }

        [JsonPropertyName("hmacMasterKey")]
        public string? HmacMasterKey { get; set; }

        [JsonPropertyName("versionMac")]
        public string? VersionMac { get; set; }
    }
}
