using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class DirectoryObjectStoreSafePathTests
{
    [Fact]
    public async Task Rejects_symlink_escape_outside_vault_root()
    {
        if (!OperatingSystem.IsWindows() && !OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux())
            return;

        var baseDir = Path.Combine(Path.GetTempPath(), "cm-safepath-" + Guid.NewGuid().ToString("N"));
        var root = Path.Combine(baseDir, "vault");
        var outside = Path.Combine(baseDir, "outside");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(outside);
        var leak = Path.Combine(outside, "leak.txt");
        await File.WriteAllTextAsync(leak, "secret");
        var link = Path.Combine(root, "escape");
        try
        {
            if (OperatingSystem.IsWindows())
                Directory.CreateSymbolicLink(link, outside);
            else
                Directory.CreateSymbolicLink(link, outside);

            var store = new DirectoryObjectStore(root);
            await Assert.ThrowsAsync<ObjectStoreException>(
                async () => await store.GetObjectAsync("escape/leak.txt"));
            // Existing ".." rejection must remain.
            await Assert.ThrowsAsync<ObjectStoreException>(
                async () => await store.GetObjectAsync("../outside/leak.txt"));
        }
        catch (IOException) when (OperatingSystem.IsWindows())
        {
            // Creating symlinks on Windows often needs Developer Mode / elevation.
            // Skip rather than fail the suite.
        }
        finally
        {
            try { Directory.Delete(baseDir, true); } catch { /* ignore */ }
        }
    }
}
