using Xunit;
using CryptoMako.Vault;

namespace CryptoMako.Vault.Tests;

public class BackupPathOverlapTests
{
    [Fact]
    public void Resolve_returns_full_path()
    {
        var dir = Path.Combine(Path.GetTempPath(), "cm-overlap-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var resolved = BackupPathOverlap.Resolve(dir);
            Assert.Equal(
                Path.GetFullPath(dir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                resolved,
                ignoreCase: OperatingSystem.IsWindows() || OperatingSystem.IsMacOS());
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

    [Fact]
    public void SoftWarnOnAdd_when_nested_under_existing()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-ov-root-" + Guid.NewGuid().ToString("N"));
        var child = Path.Combine(root, "child");
        Directory.CreateDirectory(child);
        try
        {
            var existing = new[] { BackupSource.Create(root, "Root") };
            var warn = BackupPathOverlap.SoftWarnOnAdd(existing, child);
            Assert.NotNull(warn);
            Assert.Contains("overlap", warn!, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public void SoftWarnOnAdd_null_when_disjoint()
    {
        var a = Path.Combine(Path.GetTempPath(), "cm-ov-a-" + Guid.NewGuid().ToString("N"));
        var b = Path.Combine(Path.GetTempPath(), "cm-ov-b-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(a);
        Directory.CreateDirectory(b);
        try
        {
            var existing = new[] { BackupSource.Create(a, "A") };
            Assert.Null(BackupPathOverlap.SoftWarnOnAdd(existing, b));
        }
        finally
        {
            try { Directory.Delete(a, recursive: true); } catch { }
            try { Directory.Delete(b, recursive: true); } catch { }
        }
    }

    [Fact]
    public void ThrowIfOverlapping_when_parent_and_child()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-ov-hard-" + Guid.NewGuid().ToString("N"));
        var child = Path.Combine(root, "nested");
        Directory.CreateDirectory(child);
        try
        {
            var sources = new[]
            {
                BackupSource.Create(root, "Root"),
                BackupSource.Create(child, "Child"),
            };
            var ex = Assert.Throws<InvalidOperationException>(() => BackupPathOverlap.ThrowIfOverlapping(sources));
            Assert.Contains("refused", ex.Message, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public void ThrowIfOverlapping_allows_siblings()
    {
        var root = Path.Combine(Path.GetTempPath(), "cm-ov-sib-" + Guid.NewGuid().ToString("N"));
        var a = Path.Combine(root, "a");
        var b = Path.Combine(root, "b");
        Directory.CreateDirectory(a);
        Directory.CreateDirectory(b);
        try
        {
            var sources = new[]
            {
                BackupSource.Create(a, "A"),
                BackupSource.Create(b, "B"),
            };
            BackupPathOverlap.ThrowIfOverlapping(sources);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public void BackupSourcesStore_roundtrips_json()
    {
        var path = Path.Combine(Path.GetTempPath(), "cm-sources-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new BackupSourcesStore();
            var tempRoot = Path.GetTempPath();
            store.Sources.Add(BackupSource.Create(tempRoot, "TempHost"));
            store.SaveToFile(path);
            var back = BackupSourcesStore.LoadFromFile(path);
            Assert.Single(back.Sources);
            Assert.Equal(
                BackupSource.ComposeVaultFolderName("TempHost", tempRoot),
                back.Sources[0].VaultFolderName);
            Assert.False(string.IsNullOrWhiteSpace(back.Sources[0].Id));
            // Legacy / fresh sources have no lastFullSyncAt until first successful run.
            Assert.Null(back.Sources[0].LastFullSyncAt);
            Assert.DoesNotContain("lastFullSyncAt", File.ReadAllText(path), StringComparison.Ordinal);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }

    [Fact]
    public void BackupSource_lastFullSyncAt_roundtrips_json()
    {
        var path = Path.Combine(Path.GetTempPath(), "cm-sources-lfs-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var stamp = DateTimeOffset.Parse("2023-11-14T22:13:20Z");
            var store = new BackupSourcesStore();
            var src = BackupSource.Create(Path.GetTempPath(), "Host");
            src.LastFullSyncAt = stamp;
            store.Sources.Add(src);
            store.SaveToFile(path);

            var json = File.ReadAllText(path);
            Assert.Contains("lastFullSyncAt", json, StringComparison.Ordinal);

            var back = BackupSourcesStore.LoadFromFile(path);
            Assert.Single(back.Sources);
            Assert.NotNull(back.Sources[0].LastFullSyncAt);
            Assert.Equal(stamp.UtcTicks, back.Sources[0].LastFullSyncAt!.Value.UtcTicks);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }

    [Fact]
    public void BackupSource_legacy_json_without_lastFullSyncAt_loads_null()
    {
        var path = Path.Combine(Path.GetTempPath(), "cm-sources-legacy-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            // Minimal legacy shape (no lastFullSyncAt key) must decode with null stamp.
            File.WriteAllText(path, """
                {"sources":[{"id":"s1","path":"C:\\tmp","vaultFolderName":"X","addedAt":"2024-01-01T00:00:00Z"}]}
                """);
            var back = BackupSourcesStore.LoadFromFile(path);
            Assert.Single(back.Sources);
            Assert.Equal("s1", back.Sources[0].Id);
            Assert.Null(back.Sources[0].LastFullSyncAt);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }
}
