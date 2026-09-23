using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Dorssel.Security.Cryptography;

namespace CryptoMako.Vault;

/// <summary>Cryptomator format-8 cryptor (SIV filenames + SIV_GCM content).</summary>
public sealed class Cryptor : IDisposable
{
    public const int NonceLen = 12;
    public const int TagLen = 16;
    public const int CleartextChunkSize = 32 * 1024;
    private const int FileHeaderLegacyPayloadSize = 8;
    private const int FileHeaderPayloadSize = FileHeaderLegacyPayloadSize + 32; // 40
    public const int FileHeaderSize = NonceLen + FileHeaderPayloadSize + TagLen; // 68

    private readonly Masterkey _masterkey;
    private readonly AesSiv _siv;

    public Cryptor(Masterkey masterkey)
    {
        _masterkey = masterkey;
        _siv = new AesSiv(masterkey.SivKey);
    }

    public string EncryptDirId(ReadOnlySpan<byte> dirId)
    {
        var ciphertext = new byte[dirId.Length + 16];
        // Dir-id SIV uses NO associated data (not an empty AD component).
        _siv.Encrypt(dirId.ToArray(), ciphertext);
        var digest = SHA1.HashData(ciphertext);
        return Base32Rfc4648.Encode(digest);
    }

    public string DecryptFileName(string ciphertextName, ReadOnlySpan<byte> dirId)
    {
        var ciphertext = EncodingUtil.Base64Url(ciphertextName);
        if (ciphertext.Length < 16)
            throw new CryptographicException("ciphertext name too short");
        var plaintext = new byte[ciphertext.Length - 16];
        // Filenames always authenticate with AD = dirId bytes (empty dirId => one empty AD).
        _siv.Decrypt(ciphertext, plaintext, dirId.ToArray());
        return Encoding.UTF8.GetString(plaintext);
    }

    public byte[] DecryptContent(ReadOnlySpan<byte> ciphertext)
    {
        if (ciphertext.Length < FileHeaderSize)
            throw new CryptographicException("ciphertext shorter than file header");

        var headerNonce = ciphertext[..NonceLen].ToArray();
        var headerCt = ciphertext.Slice(NonceLen, FileHeaderPayloadSize).ToArray();
        var headerTag = ciphertext.Slice(NonceLen + FileHeaderPayloadSize, TagLen).ToArray();

        var headerClear = new byte[FileHeaderPayloadSize];
        using (var gcm = new AesGcm(_masterkey.AesKey, TagLen))
        {
            gcm.Decrypt(headerNonce, headerCt, headerTag, headerClear, ReadOnlySpan<byte>.Empty);
        }

        var fileKey = headerClear.AsSpan(FileHeaderLegacyPayloadSize, 32).ToArray();
        try
        {
            var clear = new MemoryStream();
            var offset = FileHeaderSize;
            ulong chunkNumber = 0;
            var cipherChunkSize = NonceLen + CleartextChunkSize + TagLen;
            Span<byte> aad = stackalloc byte[8 + NonceLen];

            while (offset < ciphertext.Length)
            {
                var remaining = ciphertext.Length - offset;
                var thisLen = Math.Min(remaining, cipherChunkSize);
                if (thisLen < NonceLen + TagLen)
                    throw new CryptographicException("truncated content chunk");

                var chunk = ciphertext.Slice(offset, thisLen);
                var chunkNonce = chunk[..NonceLen].ToArray();
                var chunkCt = chunk.Slice(NonceLen, thisLen - NonceLen - TagLen).ToArray();
                var chunkTag = chunk.Slice(thisLen - TagLen, TagLen).ToArray();

                BinaryPrimitives.WriteUInt64BigEndian(aad[..8], chunkNumber);
                headerNonce.CopyTo(aad[8..]);

                var plainChunk = new byte[chunkCt.Length];
                using (var gcm = new AesGcm(fileKey, TagLen))
                {
                    gcm.Decrypt(chunkNonce, chunkCt, chunkTag, plainChunk, aad);
                }
                clear.Write(plainChunk);
                offset += thisLen;
                chunkNumber++;
            }

            return clear.ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(fileKey);
            CryptographicOperations.ZeroMemory(headerClear);
        }
    }

    public void Dispose() => _siv.Dispose();
}
