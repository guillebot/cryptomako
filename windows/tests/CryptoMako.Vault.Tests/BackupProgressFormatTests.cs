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

    [Fact]
    public void Progress_percent_with_skipped_bytes_already_done()
    {
        var u = new BackupSyncProgressUpdate
        {
            FilesDone = 14,
            FilesTotal = 16,
            FilesSkipped = 14,
            FilesScanned = 16,
            BytesDone = 1000,
            BytesTotal = 2000,
            BytesScanned = 2000,
        };
        Assert.Equal(50, u.Percent);
        Assert.Equal(16, Math.Max(u.FilesScanned, u.FilesTotal));
    }

    [Fact]
    public void BuildBackupProgressLabel_scanning_includes_count_bytes_and_path()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "scanning",
            FilesScanned = 42,
            BytesScanned = 1536,
            CurrentPath = "Documents/notes.txt",
            // Poisonous if label builder preferred percent branch: Done==Total => 100%.
            FilesDone = 42,
            FilesTotal = 42,
            BytesDone = 1536,
            BytesTotal = 1536,
        };
        var label = MainViewModel.BuildBackupProgressLabel(u);
        Assert.StartsWith("Counting local files...", label);
        Assert.Contains("42 files", label);
        Assert.Contains("1.5 KB found so far", label);
        Assert.Contains("Documents/notes.txt", label);
        Assert.DoesNotContain("%", label);
    }

    [Fact]
    public void BuildBackupProgressLabel_scanning_empty_stays_counting()
    {
        var u = new BackupSyncProgressUpdate { Phase = "scanning" };
        Assert.Equal("Counting local files...", MainViewModel.BuildBackupProgressLabel(u));
    }

    [Fact]
    public void BuildBackupProgressLabel_uploading_uses_percent()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "uploading",
            FilesDone = 1,
            FilesTotal = 4,
            FilesScanned = 4,
            BytesDone = 50,
            BytesTotal = 100,
            BytesScanned = 100,
        };
        var label = MainViewModel.BuildBackupProgressLabel(u);
        Assert.StartsWith("50%", label);
        Assert.Contains("1/4 files", label);
    }

    [Fact]
    public void DisplayProgressPercent_floors_below_100_when_files_remain()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "uploading",
            FilesDone = 30000,
            FilesTotal = 35000,
            FilesScanned = 35000,
            BytesDone = 9_910_000_000,
            BytesTotal = 9_940_000_000,
        };
        // Raw Percent ~99.7 would round to 100% with "{0:0}%"; display must stay <=99.
        Assert.True(u.Percent >= 99.5);
        Assert.Equal(99, MainViewModel.DisplayProgressPercent(u));
    }

    [Fact]
    public void DisplayProgressPercent_100_when_done_phase()
    {
        var u = new BackupSyncProgressUpdate { Phase = "done", FilesDone = 1, FilesTotal = 1, BytesDone = 1, BytesTotal = 1 };
        Assert.Equal(100, MainViewModel.DisplayProgressPercent(u));
    }
}
