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
    private const int FileHeaderPayloadSize = FileHeaderLegacyPayloadSize + 32;
    public const int FileHeaderSize = NonceLen + FileHeaderPayloadSize + TagLen;

    private readonly Masterkey _masterkey;
    private readonly AesSiv _siv;
    private readonly bool _ownsMasterkey;

    public Cryptor(Masterkey masterkey, bool ownsMasterkey = false)
    {
        _masterkey = masterkey;
        _ownsMasterkey = ownsMasterkey;
        // SivKey allocates aes||mac copy ? zero after AesSiv takes its own key material.
        var sivKey = masterkey.SivKey;
        try { _siv = new AesSiv(sivKey); }
        finally { CryptographicOperations.ZeroMemory(sivKey); }
    }

    public static Cryptor CreateWorker(Masterkey shared) =>
        new(shared.Clone(), ownsMasterkey: true);

    public string EncryptDirId(ReadOnlySpan<byte> dirId)
    {
        var ciphertext = new byte[dirId.Length + 16];
        _siv.Encrypt(dirId.ToArray(), ciphertext);
        return Base32Rfc4648.Encode(SHA1.HashData(ciphertext));
    }

    public string EncryptFileName(string cleartextName, ReadOnlySpan<byte> dirId)
    {
        var clear = Encoding.UTF8.GetBytes(cleartextName.Normalize(NormalizationForm.FormC));
        var ciphertext = new byte[clear.Length + 16];
        _siv.Encrypt(clear, ciphertext, dirId.ToArray());
        return EncodingUtil.ToBase64Url(ciphertext);
    }

    public string DecryptFileName(string ciphertextName, ReadOnlySpan<byte> dirId)
    {
        var ciphertext = EncodingUtil.Base64Url(ciphertextName);
        if (ciphertext.Length < 16)
            throw new CryptographicException("ciphertext name too short");
        var plaintext = new byte[ciphertext.Length - 16];
        _siv.Decrypt(ciphertext, plaintext, dirId.ToArray());
        return Encoding.UTF8.GetString(plaintext);
    }

    public byte[] EncryptContent(ReadOnlySpan<byte> cleartext)
    {
        var headerNonce = RandomNumberGenerator.GetBytes(NonceLen);
        var fileKey = RandomNumberGenerator.GetBytes(32);
        try
        {
            var headerClear = new byte[FileHeaderPayloadSize];
            headerClear.AsSpan(0, FileHeaderLegacyPayloadSize).Fill(0xFF);
            fileKey.CopyTo(headerClear.AsSpan(FileHeaderLegacyPayloadSize));

            var headerCt = new byte[FileHeaderPayloadSize];
            var headerTag = new byte[TagLen];
            using (var gcm = new AesGcm(_masterkey.AesKey, TagLen))
            {
                gcm.Encrypt(headerNonce, headerClear, headerCt, headerTag, ReadOnlySpan<byte>.Empty);
            }

            using var output = new MemoryStream(FileHeaderSize + cleartext.Length + 64);
            output.Write(headerNonce);
            output.Write(headerCt);
            output.Write(headerTag);

            Span<byte> aad = stackalloc byte[8 + NonceLen];
            var offset = 0;
            ulong chunkNumber = 0;
            while (offset < cleartext.Length || (cleartext.Length == 0 && chunkNumber == 0))
            {
                // Empty file: still no content chunks (Cryptomator writes header only).
                if (cleartext.Length == 0)
                    break;

                var take = Math.Min(CleartextChunkSize, cleartext.Length - offset);
                var plainChunk = cleartext.Slice(offset, take);
                var chunkNonce = RandomNumberGenerator.GetBytes(NonceLen);
                var chunkCt = new byte[take];
                var chunkTag = new byte[TagLen];

                BinaryPrimitives.WriteUInt64BigEndian(aad[..8], chunkNumber);
                headerNonce.CopyTo(aad[8..]);

                using (var gcm = new AesGcm(fileKey, TagLen))
                {
                    gcm.Encrypt(chunkNonce, plainChunk, chunkCt, chunkTag, aad);
                }

                output.Write(chunkNonce);
                output.Write(chunkCt);
                output.Write(chunkTag);

                offset += take;
                chunkNumber++;
                if (offset >= cleartext.Length)
                    break;
            }

            CryptographicOperations.ZeroMemory(headerClear);
            return output.ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(fileKey);
        }
    }

    /// <summary>
    /// Cleartext payload length implied by Cryptomator format-8 ciphertext length
    /// (header + per-chunk nonce/tag overhead). Used for CfAPI placeholder FileSize
    /// so Explorer triggers FETCH_DATA with a non-zero logical size.
    /// </summary>
    public static long EstimateCleartextSize(long ciphertextLength)
    {
        if (ciphertextLength < FileHeaderSize)
            return 0;
        long remaining = ciphertextLength - FileHeaderSize;
        long clear = 0;
        const int maxCipherChunk = NonceLen + CleartextChunkSize + TagLen;
        const int overhead = NonceLen + TagLen;
        while (remaining > 0)
        {
            var thisLen = Math.Min(remaining, maxCipherChunk);
            if (thisLen <= overhead)
                break;
            clear += thisLen - overhead;
            remaining -= thisLen;
        }
        return clear;
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

    public void Dispose()
    {
        _siv.Dispose();
        if (_ownsMasterkey)
            _masterkey.Dispose();
    }
}
