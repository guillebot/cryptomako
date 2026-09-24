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
        // Policies: Partial hydration + auto-dehydrate. Population Full (PARTIAL unsupported by
        // platform; AlwaysFull rejects CfCreatePlaceholders). AttachSession before Register;
        // Connect ASAP; seed placeholders; gate Explorer on cross-process ENUM.
        // AllowPinning lets users "Always keep on this device" without forcing global pin.
        var info = new Windows.Storage.Provider.StorageProviderSyncRootInfo
        {
            Id = syncRootId,
            DisplayNameResource = "CryptoMako",
            IconResource = ResolveShellIconResource(),
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
            // Do NOT set RecycleBinUri. A fake https://cryptomako.local/recycle caused Explorer
            // context-menu / shell verbs to block on DNS (~2–7s+). Omit until a real recycle UX exists.
            Context = Windows.Security.Cryptography.CryptographicBuffer.ConvertStringToBinary(
                syncRootId, Windows.Security.Cryptography.BinaryStringEncoding.Utf8),
        };
        Windows.Storage.Provider.StorageProviderSyncRootManager.Register(info);
        // Do NOT sleep here â€” a registered-but-not-yet-CfConnected root makes Explorer show
        // "The cloud operation is invalid" (0x8007016A). Caller must CfConnectSyncRoot immediately.
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


    /// <summary>
    /// Explorer SyncRoot IconResource: branded AppIcon.ico (visible cyan mark on dark tile),
    /// not shell32.dll,50 (generic / often reads as a solid dark tile in the nav pane).
    /// Copies into %LOCALAPPDATA%\CryptoMako\Assets so the path stays stable across publish folds.
    /// Format: absolute .ico path + ",0". Falls back to shell32 only if no brand asset is found.
    /// </summary>
    internal static string ResolveShellIconResource()
    {
        const string fallback = @"%SystemRoot%\system32\shell32.dll,50";
        try
        {
            var localAssets = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CryptoMako", "Assets");
            Directory.CreateDirectory(localAssets);
            var dest = Path.Combine(localAssets, "AppIcon.ico");

            // Prefer a fresh copy from the running host (Desktop publish ships Assets\AppIcon.ico).
            foreach (var src in EnumerateBrandIconCandidates())
            {
                try
                {
                    if (!File.Exists(src)) continue;
                    var copy = !File.Exists(dest)
                               || new FileInfo(src).Length != new FileInfo(dest).Length
                               || File.GetLastWriteTimeUtc(src) > File.GetLastWriteTimeUtc(dest);
                    if (copy)
                        File.Copy(src, dest, overwrite: true);
                    if (File.Exists(dest))
                        return dest + ",0";
                }
                catch
                {
                    // try next candidate
                }
            }

            if (File.Exists(dest))
                return dest + ",0";
        }
        catch
        {
            // fall through
        }
        return fallback;
    }

    private static IEnumerable<string> EnumerateBrandIconCandidates()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string?[] bases =
        {
            AppContext.BaseDirectory,
            Path.GetDirectoryName(Environment.ProcessPath),
            Path.GetDirectoryName(typeof(ShellSyncRoot).Assembly.Location),
        };
        foreach (var b in bases)
        {
            if (string.IsNullOrWhiteSpace(b)) continue;
            foreach (var rel in new[]
                     {
                         Path.Combine("Assets", "AppIcon.ico"),
                         "AppIcon.ico",
                     })
            {
                string full;
                try { full = Path.GetFullPath(Path.Combine(b, rel)); }
                catch { continue; }
                if (seen.Add(full))
                    yield return full;
            }
        }
    }

    internal static bool TryRegisterViaRegistry(string syncRootPath, string syncRootId)
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager\" + syncRootId);
            if (key is null) return false;
            key.SetValue("DisplayNameResource", "CryptoMako", Microsoft.Win32.RegistryValueKind.String);
            key.SetValue("IconResource", ResolveShellIconResource(), Microsoft.Win32.RegistryValueKind.String);
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

    /// <summary>
    /// Best-effort tear-down of EVERY CryptoMako sync-root registration so Explorer never keeps
    /// duplicate / dead sidebar links ("The cloud operation is invalid").
    /// Scrubs: all WinRT CryptoMako!* roots, CfUnregister on LocalAppData CryptoMako SyncRoot*
    /// trees, all HKCU SyncRootManager CryptoMako!* keys, and Desktop NameSpace CLSID pins whose
    /// target path is under CryptoMako. Call before every fresh Register/Connect.
    /// </summary>
    public static string TryCleanupOrphans(string syncRootPath, string accountName)
    {
        var notes = new List<string>();
        var full = string.IsNullOrWhiteSpace(syncRootPath)
            ? ""
            : Path.GetFullPath(syncRootPath);

        // 1) Live account id (WinRT + SyncRootManager stub).
        try
        {
            if (TryUnregister(accountName, out var detail) && !string.IsNullOrWhiteSpace(detail))
                notes.Add("account:" + detail);
        }
        catch (Exception ex)
        {
            notes.Add("account-unreg:" + ex.Message);
        }

        // 2) EVERY WinRT StorageProviderSyncRoot with CryptoMako! prefix (winrt3 / smoke / â€¦).
        try
        {
            var n = TryUnregisterAllCryptoMakoWinRtRoots();
            if (n > 0) notes.Add("winrt-all:" + n);
        }
        catch (Exception ex)
        {
            notes.Add("winrt-all:" + ex.Message.Split('\n')[0]);
        }

        // 3) CfUnregister primary path + every SyncRoot* / cfapi-* under LocalAppData\CryptoMako.
        var cfN = 0;
        foreach (var path in EnumerateCryptoMakoSyncRootPaths(full))
        {
            try
            {
                _ = Vanara.PInvoke.CldApi.CfUnregisterSyncRoot(path);
                cfN++;
            }
            catch
            {
                // Not registered / already clean â€” ignore.
            }
        }
        if (cfN > 0) notes.Add("CfUnregister:" + cfN);

        // 4) Drop ALL CryptoMako!* SyncRootManager keys (including current â€” re-Register recreates).
        try
        {
            var n = TryUnregisterAllCryptoMakoRegistryKeys();
            if (n > 0) notes.Add("registry-all:" + n);
        }
        catch (Exception ex)
        {
            notes.Add("registry-all:" + ex.Message);
        }

        // 5) Desktop NameSpace CLSID pins (duplicate Explorer sidebar entries).
        try
        {
            var n = TryUnregisterCryptoMakoNamespacePins();
            if (n > 0) notes.Add("namespace:" + n);
        }
        catch (Exception ex)
        {
            notes.Add("namespace:" + ex.Message);
        }

        return notes.Count == 0 ? "nothing" : string.Join("; ", notes);
    }

#if CFAPI_WINRT
    [SupportedOSPlatform("windows10.0.17134")]
    private static int TryUnregisterAllCryptoMakoWinRtRoots()
    {
        if (!SupportsWinRt) return 0;
        var removed = 0;
        try
        {
            var roots = Windows.Storage.Provider.StorageProviderSyncRootManager.GetCurrentSyncRoots();
            // Snapshot ids first â€” Unregister mutates the live collection.
            var ids = new List<string>();
            foreach (var root in roots)
            {
                var id = root.Id ?? "";
                if (id.StartsWith(CloudFilesProvider.SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
                    ids.Add(id);
            }
            foreach (var id in ids)
            {
                try
                {
                    Windows.Storage.Provider.StorageProviderSyncRootManager.Unregister(id);
                    removed++;
                }
                catch { /* ignore single-id failures */ }
            }
        }
        catch { /* GetCurrentSyncRoots unavailable */ }
        return removed;
    }
#else
    private static int TryUnregisterAllCryptoMakoWinRtRoots() => 0;
#endif

    private static IEnumerable<string> EnumerateCryptoMakoSyncRootPaths(string primaryFull)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(primaryFull) && seen.Add(primaryFull))
            yield return primaryFull;

        string baseDir;
        try
        {
            baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CryptoMako");
        }
        catch { yield break; }
        if (!Directory.Exists(baseDir)) yield break;

        IEnumerable<string> dirs;
        try { dirs = Directory.GetDirectories(baseDir); }
        catch { yield break; }

        foreach (var dir in dirs)
        {
            string name;
            try { name = Path.GetFileName(dir); }
            catch { continue; }
            if (name is null) continue;
            if (!(name.StartsWith("SyncRoot", StringComparison.OrdinalIgnoreCase)
                  || name.StartsWith("cfapi-", StringComparison.OrdinalIgnoreCase)
                  || name.Equals("vanara-probe", StringComparison.OrdinalIgnoreCase)))
                continue;
            string full;
            try { full = Path.GetFullPath(dir); }
            catch { continue; }
            if (seen.Add(full))
                yield return full;
        }
    }

    /// <summary>Remove every HKCU SyncRootManager\CryptoMako!* key (full scrub before re-Register).</summary>
    internal static int TryUnregisterAllCryptoMakoRegistryKeys()
    {
        var removed = 0;
        using var root = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager", writable: true);
        if (root is null) return 0;
        foreach (var name in root.GetSubKeyNames())
        {
            if (!name.StartsWith(CloudFilesProvider.SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
                continue;
            try
            {
                root.DeleteSubKeyTree(name, throwOnMissingSubKey: false);
                removed++;
            }
            catch { /* ignore */ }
        }
        return removed;
    }

    /// <summary>
    /// Remove Explorer Desktop\NameSpace CLSID pins that point at CryptoMako sync roots
    /// (WinRT leaves these behind; duplicates show as multiple dead CryptoMako sidebar links).
    /// </summary>
    internal static int TryUnregisterCryptoMakoNamespacePins()
    {
        var removed = 0;
        const string nsPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace";
        using var ns = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(nsPath, writable: true);
        if (ns is null) return 0;

        foreach (var guid in ns.GetSubKeyNames())
        {
            string? def = null;
            string? target = null;
            try
            {
                using var sub = ns.OpenSubKey(guid);
                def = sub?.GetValue(null) as string;
            }
            catch { /* ignore */ }
            try
            {
                using var init = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"Software\Classes\CLSID\" + guid + @"\Instance\InitPropertyBag");
                target = init?.GetValue("TargetFolderPath") as string;
            }
            catch { /* ignore */ }

            var isCryptoMako =
                (!string.IsNullOrEmpty(def) && def.StartsWith(CloudFilesProvider.SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
                || (!string.IsNullOrEmpty(target) && target.IndexOf("CryptoMako", StringComparison.OrdinalIgnoreCase) >= 0);
            if (!isCryptoMako) continue;

            try
            {
                ns.DeleteSubKeyTree(guid, throwOnMissingSubKey: false);
                removed++;
            }
            catch { /* ignore */ }
            try
            {
                Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(
                    @"Software\Classes\CLSID\" + guid, throwOnMissingSubKey: false);
            }
            catch { /* ignore */ }
        }
        return removed;
    }

    internal static int TryUnregisterRegistryByPath(string syncRootPathFull)
    {
        var removed = 0;
        using var root = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager", writable: true);
        if (root is null) return 0;
        foreach (var name in root.GetSubKeyNames())
        {
            if (!name.StartsWith(CloudFilesProvider.SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
                continue;
            try
            {
                using var sub = root.OpenSubKey(name);
                var path = sub?.GetValue("UserSyncRootPath") as string;
                if (string.IsNullOrWhiteSpace(path)) continue;
                string full;
                try { full = Path.GetFullPath(path); }
                catch { continue; }
                if (!full.Equals(syncRootPathFull, StringComparison.OrdinalIgnoreCase))
                    continue;
            }
            catch { continue; }
            try
            {
                root.DeleteSubKeyTree(name, throwOnMissingSubKey: false);
                removed++;
            }
            catch { /* ignore */ }
        }
        return removed;
    }

    /// <summary>
    /// Remove CryptoMako!* registry stubs that are not the live account id (smoke leftovers).
    /// </summary>
    internal static int TryUnregisterStaleCryptoMakoRegistryKeys(string accountName)
    {
        var keep = BuildSyncRootId(accountName);
        var removed = 0;
        using var root = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager", writable: true);
        if (root is null) return 0;
        foreach (var name in root.GetSubKeyNames())
        {
            if (!name.StartsWith(CloudFilesProvider.SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
                continue;
            if (name.Equals(keep, StringComparison.OrdinalIgnoreCase))
                continue;
            // Only drop keys that look like short smoke aliases (no SID segment) or point at
            // CryptoMako LocalAppData trees â€” never touch other providers.
            var parts = name.Split('!');
            var looksSmoke = parts.Length < 3; // CryptoMako!hydrate
            var underCryptoMako = false;
            try
            {
                using var sub = root.OpenSubKey(name);
                var path = sub?.GetValue("UserSyncRootPath") as string ?? "";
                underCryptoMako = path.IndexOf("CryptoMako", StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch { /* ignore */ }
            if (!looksSmoke && !underCryptoMako) continue;
            try
            {
                root.DeleteSubKeyTree(name, throwOnMissingSubKey: false);
                removed++;
            }
            catch { /* ignore */ }
        }
        return removed;
    }

}



