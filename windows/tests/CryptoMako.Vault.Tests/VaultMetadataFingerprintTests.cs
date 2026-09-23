using Xunit;
using CryptoMako.Vault;

namespace CryptoMako.Vault.Tests;

public class VaultMetadataFingerprintTests
{
    [Fact]
    public async Task DirectoryObjectStore_head_etag_includes_mtime()
    {
        var dir = Path.Combine(Path.GetTempPath(), "cm-fp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, "vault.cryptomator");
        await File.WriteAllTextAsync(file, "jwt-placeholder");
        try
        {
            var store = new DirectoryObjectStore(dir);
            var head1 = await store.HeadObjectAsync("vault.cryptomator");
            Assert.False(string.IsNullOrEmpty(head1.ETag));
            await Task.Delay(20);
            await File.WriteAllTextAsync(file, "jwt-placeholder-changed");
            var head2 = await store.HeadObjectAsync("vault.cryptomator");
            Assert.NotEqual(head1.ETag, head2.ETag);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }
}
