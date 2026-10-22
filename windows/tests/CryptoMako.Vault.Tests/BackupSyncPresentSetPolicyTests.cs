using CryptoMako.Vault;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class BackupSyncPresentSetPolicyTests
{
    [Fact]
    public void Excluded_stays_in_prune_allow_set_and_is_not_upload_eligible()
    {
        Assert.Equal(
            BackupSyncScanDisposition.PresentDoNotUpload,
            BackupSyncPresentSetPolicy.Disposition(isHidden: false, isExcluded: true));
        Assert.True(BackupSyncPresentSetPolicy.RetainInPruneAllowSet(true, true));
    }

    [Fact]
    public void Hidden_stays_in_prune_allow_set()
    {
        Assert.Equal(
            BackupSyncScanDisposition.PresentDoNotUpload,
            BackupSyncPresentSetPolicy.Disposition(isHidden: true, isExcluded: false));
    }

    [Fact]
    public void Eligible_path_is_upload_eligible()
    {
        Assert.Equal(
            BackupSyncScanDisposition.PresentUploadEligible,
            BackupSyncPresentSetPolicy.Disposition(false, false));
    }

    [Fact]
    public void Backup_mode_does_not_retain_present_set()
    {
        Assert.False(BackupSyncPresentSetPolicy.RetainInPruneAllowSet(false, true));
    }
}
