using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupRelativePathTests
{
    [Fact]
    public void Make_nested_relative()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-rel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "a"));
        var file = Path.Combine(root, "a", "b.txt");
        File.WriteAllText(file, "x");
        try
        {
            Assert.Equal("a/b.txt", BackupRelativePath.Make(file, root));
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { /* ignore */ }
        }
    }

    [Fact]
    public void Make_rejects_outside_root()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-rel-root-" + Guid.NewGuid().ToString("N"));
        var other = Path.Combine(Path.GetTempPath(), "cm-rel-other-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(other);
        var file = Path.Combine(other, "x.txt");
        File.WriteAllText(file, "x");
        try
        {
            Assert.Throws<BackupRelativePath.NotUnderRootException>(
                () => BackupRelativePath.Make(file, root));
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { /* ignore */ }
            try { Directory.Delete(other, true); } catch { /* ignore */ }
        }
    }
}
