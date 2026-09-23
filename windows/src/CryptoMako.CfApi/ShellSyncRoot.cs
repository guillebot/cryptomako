using System.Runtime.Versioning;
using System.Security.Principal;
using System.Text;

namespace CryptoMako.CfApi;

/// <summary>
/// Explorer shell registration. On CFAPI_WINRT builds uses real
/// StorageProviderSyncRootManager; otherwise HKCU stub fallback.
/// Id format: CryptoMako!{user SID}!{account}
/// </summary>
internal static class ShellSyncRoot
{
    public static bool SupportsWinRt =>
#if CFAPI_WINRT
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134);
#else
        false;
#endif

    public static string BuildSyncRootId(string accountName)
    {
        var account = string.IsNullOrWhiteSpace(accountName) ? "default" : accountName.Trim();
        var sid = "S-1-0";
        if (OperatingSystem.IsWindows())
        {
            try { sid = WindowsIdentity.GetCurrent().User?.Value ?? sid; }
            catch { /* keep default */ }
        }
        return CloudFilesProvider.SyncRootIdPrefix + sid + "!" + account;
    }

    public static bool TryRegisterWinRtOnly(string syncRootPath, string accountName, out string syncRootId, out string detail)
    {
        syncRootId = BuildSyncRootId(accountName);
        detail = "";
        if (!SupportsWinRt)
        {
            detail = "WinRT not compiled in this TFM";
            return false;
        }
#if CFAPI_WINRT
        try
        {
            return TryRegisterWinRt(syncRootPath, syncRootId, out detail);
        }
        catch (Exception ex)
        {
            detail = "WinRT failed: " + ex.Message;
            return false;
        }
#else
        detail = "CFAPI_WINRT undefined";
        return false;
#endif
    }

    public static bool TryRegister(string syncRootPath, string accountName, out string syncRootId, out string detail)
    {
        syncRootId = BuildSyncRootId(accountName);
        detail = "";
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
        {
            detail = "not Windows 10 1803+";
            return false;
        }

#if CFAPI_WINRT
        try
        {
            if (TryRegisterWinRt(syncRootPath, syncRootId, out detail))
                return true;
        }
        catch (Exception ex)
        {
            detail = "WinRT failed: " + ex.Message;
        }
#endif
        var ok = TryRegisterViaRegistry(syncRootPath, syncRootId);
        detail = ok ? (string.IsNullOrEmpty(detail) ? "registry stub" : detail + "; fell back to registry") : "registry stub failed";
        return ok;
    }

    public static bool TryUnregister(string accountName, out string detail)
    {
        var syncRootId = BuildSyncRootId(accountName);
        detail = "";
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
        {
            detail = "not Windows";
            return false;
        }

#if CFAPI_WINRT
        try
        {
            if (TryUnregisterWinRt(syncRootId, out detail))
            {
                TryUnregisterViaRegistry(syncRootId);
                return true;
            }
        }
        catch (Exception ex)
        {
            detail = "WinRT unregister failed: " + ex.Message;
        }
#endif
        var ok = TryUnregisterViaRegistry(syncRootId);
        if (ok && string.IsNullOrEmpty(detail)) detail = "registry stub removed";
        return ok;
    }

#if CFAPI_WINRT
    [SupportedOSPlatform("windows10.0.17134")]
    private static bool TryRegisterWinRt(string syncRootPath, string syncRootId, out string detail)
    {
        detail = "";
        Directory.CreateDirectory(syncRootPath);
        try { Windows.Storage.Provider.StorageProviderSyncRootManager.Unregister(syncRootId); }
        catch { /* not registered yet */ }

        var folder = Windows.Storage.StorageFolder.GetFolderFromPathAsync(syncRootPath).AsTask().GetAwaiter().GetResult();
        // Policies: Partial hydration + auto-dehydrate to avoid surprising full-hydrate of huge
        // trees/files. WinRT PopulationPolicy has no Partial — use Full (on-demand), never AlwaysFull.
        // AllowPinning lets users "Always keep on this device" without forcing global pin.
        var info = new Windows.Storage.Provider.StorageProviderSyncRootInfo
        {
            Id = syncRootId,
            DisplayNameResource = "CryptoMako",
            IconResource = @"%SystemRoot%\system32\shell32.dll,50",
            Version = CloudFilesProvider.ProviderVersion,
            Path = folder,
            AllowPinning = true,
            ShowSiblingsAsGroup = false,
            HydrationPolicy = Windows.Storage.Provider.StorageProviderHydrationPolicy.Partial,
            HydrationPolicyModifier = Windows.Storage.Provider.StorageProviderHydrationPolicyModifier.AutoDehydrationAllowed,
            PopulationPolicy = Windows.Storage.Provider.StorageProviderPopulationPolicy.Full,
            InSyncPolicy = Windows.Storage.Provider.StorageProviderInSyncPolicy.FileCreationTime
                | Windows.Storage.Provider.StorageProviderInSyncPolicy.DirectoryCreationTime
                | Windows.Storage.Provider.StorageProviderInSyncPolicy.FileLastWriteTime
                | Windows.Storage.Provider.StorageProviderInSyncPolicy.DirectoryLastWriteTime,
            HardlinkPolicy = Windows.Storage.Provider.StorageProviderHardlinkPolicy.None,
            ProviderId = CloudFilesProvider.ProviderId,
            RecycleBinUri = new Uri("https://cryptomako.local/recycle"),
            Context = Windows.Security.Cryptography.CryptographicBuffer.ConvertStringToBinary(
                syncRootId, Windows.Security.Cryptography.BinaryStringEncoding.Utf8),
        };
        Windows.Storage.Provider.StorageProviderSyncRootManager.Register(info);
        // Give the shell cache time to invalidate (CloudMirror Sleep(1000)).
        Thread.Sleep(1000);
        TryRegisterViaRegistry(syncRootPath, syncRootId); // belt-and-suspenders for Explorer
        detail = "WinRT StorageProviderSyncRootManager";
        return true;
    }

    [SupportedOSPlatform("windows10.0.17134")]
    private static bool TryUnregisterWinRt(string syncRootId, out string detail)
    {
        detail = "";
        Windows.Storage.Provider.StorageProviderSyncRootManager.Unregister(syncRootId);
        detail = "WinRT StorageProviderSyncRootManager";
        return true;
    }
#endif

    internal static bool TryRegisterViaRegistry(string syncRootPath, string syncRootId)
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\" + syncRootId);
            if (key is null) return false;
            key.SetValue("DisplayNameResource", "CryptoMako", Microsoft.Win32.RegistryValueKind.String);
            key.SetValue("IconResource", @"%SystemRoot%\system32\shell32.dll,50", Microsoft.Win32.RegistryValueKind.String);
            key.SetValue("UserSyncRootPath", syncRootPath, Microsoft.Win32.RegistryValueKind.String);
            key.SetValue("Version", CloudFilesProvider.ProviderVersion, Microsoft.Win32.RegistryValueKind.String);
            key.SetValue("Flags", 0, Microsoft.Win32.RegistryValueKind.DWord);
            return true;
        }
        catch { return false; }
    }

    internal static bool TryUnregisterViaRegistry(string syncRootId)
    {
        try
        {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\" + syncRootId,
                throwOnMissingSubKey: false);
            return true;
        }
        catch { return false; }
    }
}



