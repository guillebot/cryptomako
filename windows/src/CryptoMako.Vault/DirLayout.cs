using System.Security.Cryptography;
using System.Text;

namespace CryptoMako.Vault;

internal static class DirLayout
{
    /// <summary>Object-key prefix for a directory id: {vaultPrefix}d/{xx}/{rest}/</summary>
    public static string CiphertextDirectoryPrefix(string vaultPrefix, Cryptor cryptor, string dirId)
    {
        var hash = cryptor.EncryptDirId(Encoding.UTF8.GetBytes(dirId));
        if (hash.Length < 3)
            throw new InvalidDataException("dir id hash too short");
        var head = hash[..2];
        var tail = hash[2..];
        return vaultPrefix + "d/" + head + "/" + tail + "/";
    }

    public static string ShortenedName(string ciphertextFileName)
    {
        var digest = SHA1.HashData(Encoding.UTF8.GetBytes(ciphertextFileName));
        return EncodingUtil.ToBase64Url(digest) + ".c9s";
    }
}
