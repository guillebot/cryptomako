using System.Security.Cryptography;
using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class CryptorCleartextSizeTests
{
    [Fact]
    public void EstimateCleartextSize_matches_roundtrip()
    {
        var aes = new byte[32]; var mac = new byte[32];
        RandomNumberGenerator.Fill(aes); RandomNumberGenerator.Fill(mac);
        using var mk = new Masterkey(aes, mac);
        using var c = new Cryptor(mk);
        foreach (var n in new[] { 0, 1, 100, 32 * 1024, 32 * 1024 + 1, 100_000 })
        {
            var plain = new byte[n];
            if (n > 0) RandomNumberGenerator.Fill(plain);
            var cipher = c.EncryptContent(plain);
            Assert.Equal(n, Cryptor.EstimateCleartextSize(cipher.Length));
            Assert.Equal(plain, c.DecryptContent(cipher));
        }
    }
}
