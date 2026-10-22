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
    public void BackupSyncProgressUpdate_percent_is_uploaded_over_to_upload()
    {
        var u = new BackupSyncProgressUpdate
        {
            WalkFinished = true,
            Phase = "uploading",
            FilesDone = 1,
            FilesTotal = 2,
            BytesDone = 50,
            BytesTotal = 100,
            FilesSkipped = 14,
            FilesScanned = 16,
            BytesScanned = 10_000,
        };
        // Skips must not inflate the denominator — 50/100, not 50/10000.
        Assert.Equal(50, u.Percent);
    }

    [Fact]
    public void BackupSyncProgressUpdate_percent_zero_while_scanning()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "scanning",
            WalkFinished = false,
            FilesScanned = 16,
            BytesScanned = 2000,
            BytesDone = 0,
            BytesTotal = 0,
        };
        Assert.Equal(0, u.Percent);
    }

    [Fact]
    public void Progress_percent_empty_to_upload_is_100()
    {
        var u = new BackupSyncProgressUpdate
        {
            WalkFinished = true,
            Phase = "done",
            FilesSkipped = 16,
            FilesScanned = 16,
            BytesScanned = 2000,
            BytesDone = 0,
            BytesTotal = 0,
        };
        Assert.Equal(100, u.Percent);
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
            WalkFinished = true,
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
    public void DisplayProgressPercent_floors_below_100_when_bytes_remain()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "uploading",
            WalkFinished = true,
            FilesDone = 30000,
            FilesTotal = 35000,
            FilesScanned = 35000,
            BytesDone = 9_910_000_000,
            BytesTotal = 9_940_000_000,
        };
        Assert.True(u.Percent >= 99.5);
        Assert.Equal(99, MainViewModel.DisplayProgressPercent(u));
    }

    [Fact]
    public void DisplayProgressPercent_100_when_done_phase()
    {
        var u = new BackupSyncProgressUpdate
        {
            Phase = "done",
            WalkFinished = true,
            FilesDone = 1,
            FilesTotal = 1,
            BytesDone = 1,
            BytesTotal = 1,
        };
        Assert.Equal(100, MainViewModel.DisplayProgressPercent(u));
    }
}
