namespace CryptoMako.Vault;

public sealed class Masterkey : IDisposable
{
    public byte[] AesKey { get; }
    public byte[] MacKey { get; }

    /// <summary>aesKey ‖ macKey — used for JWT HS256.</summary>
    public byte[] RawKey => EncodingUtil.Concat(AesKey, MacKey);

    /// <summary>macKey ‖ aesKey — Dorssel/RFC 5297 AesSiv key (CMAC ‖ CTR).</summary>
    public byte[] SivKey => EncodingUtil.Concat(MacKey, AesKey);

    public Masterkey(byte[] aesKey, byte[] macKey)
    {
        if (aesKey.Length != 32 || macKey.Length != 32)
            throw new ArgumentException("Master keys must be 32 bytes each.");
        AesKey = aesKey;
        MacKey = macKey;
    }

    public void Dispose()
    {
        CryptographicZero(AesKey);
        CryptographicZero(MacKey);
    }

    private static void CryptographicZero(byte[] data)
    {
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(data);
    }
}
