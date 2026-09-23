using System.Buffers.Binary;
using System.Security.Cryptography;

namespace CryptoMako.Vault;

/// <summary>RFC 3394 AES Key Wrap / Unwrap (no padding).</summary>
internal static class AesKeyWrap
{
    private static ReadOnlySpan<byte> DefaultIv => [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6];

    public static byte[] Unwrap(byte[] kek, byte[] wrapped)
    {
        if (kek.Length is not (16 or 24 or 32))
            throw new CryptographicException("Invalid KEK length.");
        if (wrapped.Length < 24 || wrapped.Length % 8 != 0)
            throw new CryptographicException("Invalid wrapped key length.");

        var n = wrapped.Length / 8 - 1;
        var a = new byte[8];
        Buffer.BlockCopy(wrapped, 0, a, 0, 8);
        var r = new byte[n * 8];
        Buffer.BlockCopy(wrapped, 8, r, 0, n * 8);

        using var aes = Aes.Create();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        aes.Key = kek;
        using var decryptor = aes.CreateDecryptor();
        var block = new byte[16];

        for (var j = 5; j >= 0; j--)
        {
            for (var i = n; i >= 1; i--)
            {
                var t = (ulong)(n * j + i);
                BinaryPrimitives.WriteUInt64BigEndian(a, BinaryPrimitives.ReadUInt64BigEndian(a) ^ t);
                Buffer.BlockCopy(a, 0, block, 0, 8);
                Buffer.BlockCopy(r, (i - 1) * 8, block, 8, 8);
                decryptor.TransformBlock(block, 0, 16, block, 0);
                Buffer.BlockCopy(block, 0, a, 0, 8);
                Buffer.BlockCopy(block, 8, r, (i - 1) * 8, 8);
            }
        }

        if (!CryptographicOperations.FixedTimeEquals(a, DefaultIv))
            throw new CryptographicException("Invalid passphrase or corrupted masterkey.");

        return r;
    }
}
