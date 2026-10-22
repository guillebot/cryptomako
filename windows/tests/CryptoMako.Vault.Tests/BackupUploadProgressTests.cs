using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupUploadProgressTests
{
    [Fact]
    public void Fraction_null_while_scanning()
    {
        Assert.Null(BackupUploadProgress.Fraction(walkFinished: false, bytesUploaded: 500, bytesToUpload: 1000));
        Assert.Equal("Scanning", BackupUploadProgress.PercentLabel(false, 500, 1000));
    }

    [Fact]
    public void Fraction_uploaded_over_to_upload()
    {
        Assert.Equal(0.5, BackupUploadProgress.Fraction(true, 500, 1000));
        Assert.Equal("50%", BackupUploadProgress.PercentLabel(true, 500, 1000));
    }

    [Fact]
    public void Fraction_empty_to_upload_is_complete()
    {
        Assert.Equal(1.0, BackupUploadProgress.Fraction(true, 0, 0));
        Assert.Equal("100%", BackupUploadProgress.PercentLabel(true, 0, 0));
    }

    [Fact]
    public void Skips_do_not_count_as_progress()
    {
        // 9 GB skipped, 1 GB to upload, 0 uploaded → 0%, not 90%.
        Assert.Equal(0.0, BackupUploadProgress.Fraction(true, 0, 1_000_000_000));
        Assert.Equal("0%", BackupUploadProgress.PercentLabel(true, 0, 1_000_000_000));
    }
}
