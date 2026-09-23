using CryptoMako.App;
using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupProgressFormatTests
{
    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(512, "512 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(1048576, "1 MB")]
    public void FormatBytes_humanizes(long bytes, string expected)
    {
        Assert.Equal(expected, MainViewModel.FormatBytes(bytes));
    }

    [Fact]
    public void FormatRate_suffix()
    {
        Assert.Equal("1 MB/s", MainViewModel.FormatRate(1024 * 1024));
        Assert.Equal("", MainViewModel.FormatRate(0));
    }

    [Fact]
    public void FormatEta_from_remaining_bytes()
    {
        Assert.Equal("ETA 10s", MainViewModel.FormatEta(0, 10_000_000, 1_000_000));
        Assert.Equal("", MainViewModel.FormatEta(100, 100, 1000));
    }

    [Fact]
    public void BackupSyncProgressUpdate_percent_prefers_bytes()
    {
        var u = new BackupSyncProgressUpdate
        {
            FilesDone = 1,
            FilesTotal = 10,
            BytesDone = 50,
            BytesTotal = 100,
        };
        Assert.Equal(50, u.Percent);
    }

    [Fact]
    public void BackupSyncProgressUpdate_percent_falls_back_to_files()
    {
        var u = new BackupSyncProgressUpdate { FilesDone = 2, FilesTotal = 8 };
        Assert.Equal(25, u.Percent);
    }
}
