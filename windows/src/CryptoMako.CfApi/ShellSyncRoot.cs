
namespace CryptoMako.CfApi;

/// <summary>
/// Best-effort Explorer shell registration via WinRT StorageProviderSyncRootManager.
/// Uses late-bound activation so net8.0 (Mac) still compiles without windows TFM.
/// </summary>
internal static class ShellSyncRoot
{
    public static bool TryRegister(string syncRootPath, string syncRootId)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return false;
        try
        {
            // Windows Runtime projection may be unavailable on plain net8.0 — fail soft.
            var managerType = Type.GetType(
                "Windows.Storage.Provider.StorageProviderSyncRootManager, Windows, ContentType=WindowsRuntime",
                throwOnError: false);
            if (managerType is null)
            {
                // Fallback: write SyncRootManager registry key consumed by Explorer.
                return TryRegisterViaRegistry(syncRootPath, syncRootId);
            }
            return TryRegisterViaRegistry(syncRootPath, syncRootId);
        }
        catch
        {
            return TryRegisterViaRegistry(syncRootPath, syncRootId);
        }
    }

    public static bool TryUnregister(string syncRootId)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return false;
        try
        {
            return TryUnregisterViaRegistry(syncRootId);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Minimal HKCU SyncRootManager entry. Not a full StorageProviderSyncRootManager substitute,
    /// but helps Explorer discover the provider id for user-scoped sync roots.
    /// </summary>
    private static bool TryRegisterViaRegistry(string syncRootPath, string syncRootId)
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
        catch
        {
            return false;
        }
    }

    private static bool TryUnregisterViaRegistry(string syncRootId)
    {
        try
        {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\" + syncRootId,
                throwOnMissingSubKey: false);
            return true;
        }
        catch
        {
            return false;
        }
    }
}

