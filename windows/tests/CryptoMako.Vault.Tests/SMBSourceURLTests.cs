using System.Text.Json;
using Xunit;

namespace CryptoMako.Vault.Tests;

public class SMBSourceURLTests
{
    [Fact]
    public void Normalize_basic_share()
    {
        Assert.Equal("smb://files.example/docs", SMBSourceURL.Normalize("smb://files.example/docs"));
    }

    [Fact]
    public void Normalize_with_subpath_and_port()
    {
        Assert.Equal(
            "smb://nas.local:445/backup/photos",
            SMBSourceURL.Normalize("smb://nas.local:445/backup/photos/"));
    }

    [Fact]
    public void Normalize_UNC()
    {
        Assert.Equal("smb://nas/share/folder", SMBSourceURL.Normalize(@"\\nas\share\folder"));
    }

    [Fact]
    public void Normalize_forward_slash_UNC()
    {
        Assert.Equal("smb://nas/share/folder", SMBSourceURL.Normalize("//nas/share/folder"));
    }

    [Fact]
    public void Reject_missing_share()
    {
        var ex = Assert.Throws<SMBSourceURL.ParseException>(() => SMBSourceURL.Normalize("smb://server-only"));
        Assert.Contains("share", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Reject_non_SMB()
    {
        Assert.Throws<SMBSourceURL.ParseException>(() => SMBSourceURL.Normalize("https://example/share"));
    }

    [Fact]
    public void ShortLabel_and_ShareName()
    {
        var n = SMBSourceURL.Normalize("smb://nas/media/films");
        Assert.Equal("media", SMBSourceURL.ShareName(n));
        Assert.Equal("nas/media", SMBSourceURL.ShortLabel(n));
    }

    [Fact]
    public void ToUnc_and_ToShareUnc()
    {
        var n = SMBSourceURL.Normalize("smb://nas/media/films");
        Assert.Equal(@"\\nas\media\films", SMBSourceURL.ToUnc(n));
        Assert.Equal(@"\\nas\media", SMBSourceURL.ToShareUnc(n));
    }

    [Fact]
    public void BackupSource_legacy_JSON_defaults_kind_folder()
    {
        var legacy = """{"id":"a","path":"C:\\tmp\\x","vaultFolderName":"X","addedAt":"2020-01-01T00:00:00Z"}""";
        var decoded = JsonSerializer.Deserialize<BackupSource>(legacy, VaultSettings.JsonOptions);
        Assert.NotNull(decoded);
        Assert.Equal(BackupSource.KindFolder, decoded!.Kind);
        Assert.Null(decoded.SmbURL);
        Assert.False(decoded.IsSMB);
    }

    [Fact]
    public void BackupSource_SMB_round_trip_never_stores_password()
    {
        var source = BackupSource.CreateSmb(
            "smb://nas/share",
            @"\\nas\share",
            username: "guille",
            vaultFolderName: "MONSTER");
        Assert.True(source.IsSMB);
        Assert.Equal("smb://nas/share", source.SmbURL);
        Assert.Equal("guille", source.SmbUsername);
        Assert.Equal("smb-password-" + source.Id, source.SmbPasswordAccount);
        Assert.Equal("MONSTER/share", source.VaultFolderName);

        var json = JsonSerializer.Serialize(source, VaultSettings.JsonOptions);
        Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("guille-secret", json);

        var decoded = JsonSerializer.Deserialize<BackupSource>(json, VaultSettings.JsonOptions);
        Assert.NotNull(decoded);
        Assert.True(decoded!.IsSMB);
        Assert.Equal(source.SmbURL, decoded.SmbURL);
        Assert.Equal("smb://nas/share", source.DisplayLocation);
    }

    [Fact]
    public void SuggestSourcePrefix_UNC_uses_share_name()
    {
        Assert.Equal("docs", BackupSource.SuggestSourcePrefix(@"\\files\docs\photos"));
        Assert.Equal("share", BackupSource.SuggestSourcePrefix(@"\\nas\share"));
    }

    [Fact]
    public void AssertSourceReachable_missing_path_fail_closed()
    {
        var missing = Path.Combine(Path.GetTempPath(), "cryptomako-missing-smb-" + Guid.NewGuid().ToString("N"));
        var ex = Assert.Throws<SMBBackupMount.MountException>(
            () => SMBBackupMount.AssertSourceReachable(missing, isSMB: true));
        Assert.Contains("fail-closed", ex.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AssertSourceReachable_missing_UNC_fail_closed()
    {
        var unc = @"\\127.0.0.1\cryptomako-no-such-share-" + Guid.NewGuid().ToString("N");
        var ex = Assert.Throws<SMBBackupMount.MountException>(
            () => SMBBackupMount.AssertSourceReachable(unc, isSMB: true));
        Assert.Contains("fail-closed", ex.Message, StringComparison.OrdinalIgnoreCase);
    }
}
