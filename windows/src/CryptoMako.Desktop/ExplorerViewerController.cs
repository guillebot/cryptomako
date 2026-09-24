using System.Diagnostics;
using System.Runtime.InteropServices;
using CryptoMako.App;
using CryptoMako.CfApi;

namespace CryptoMako.Desktop;

/// <summary>
/// Owns the soft CfAPI <see cref="CloudFilesProvider"/> lifetime for the WinUI host.
/// On successful Connect, binds the provider to <see cref="MainViewModel.ExplorerViewer"/>
/// so Lock High can Disconnect it. Unregister is explicit / process exit — not Lock.
/// Soft Connect failures must not clear vault-unlocked state (macOS soft Finder semantics).
/// </summary>
internal sealed class ExplorerViewerController : IDisposable
{
    /// <summary>HRESULT 0x8007016A — ERROR_CLOUD_FILE_ACCESS_DENIED / "The cloud operation is invalid".</summary>
    private const int CloudOperationInvalidHResult = unchecked((int)0x8007016A);

    private readonly MainViewModel _vm;
    private CloudFilesProvider? _provider;
    private bool _disposed;

    public ExplorerViewerController(MainViewModel vm) => _vm = vm;

    public bool IsConnected => _provider?.IsConnected == true;

    public string SyncRootPath => AppPaths.SyncRootPath;

    /// <summary>
    /// Scrub orphans → fresh root dir → Register → CfConnect (keep alive) → soft populate →
    /// probe list. Opens Explorer ONLY when connected AND probe succeeds (never on 0x8007016A).
    /// </summary>
    public async Task ConnectAsync(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_vm.Session is null)
            throw new InvalidOperationException("unlock vault before connecting Explorer viewer");

        _provider ??= new CloudFilesProvider(AppPaths.SyncRootPath);

        if (!_provider.IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI Explorer viewer requires Windows 10 1803+.");

        var registeredThisCall = false;
        try
        {
            // Always start clean: disconnect + scrub ALL CryptoMako orphans, then fresh root dir.
            // Never leave a registered-but-disconnected root for Explorer to open.
            try { _provider.Disconnect(); } catch { /* ignore */ }
            var scrub = _provider.CleanupOrphans("default");
            _vm.LogLine("CfAPI orphan cleanup: " + scrub.Replace('\n', ' '));
            try { _provider.Dispose(); } catch { /* ignore */ }
            EnsureFreshSyncRootDirectory();
            _provider = new CloudFilesProvider(AppPaths.SyncRootPath);

            // Register then CfConnect with no await in between (minimize shell race).
            EnsureRegistered("default");
            registeredThisCall = true;

            _provider.Connect();
            if (!_provider.IsConnected)
                throw new InvalidOperationException("CfConnectSyncRoot did not leave the provider connected");

            _provider.AttachSession(_vm.Session);
            _vm.BindExplorerViewer(_provider);

            try
            {
                var n = await _provider.PopulateRootPlaceholdersAsync(recursive: false, ct: ct)
                    .ConfigureAwait(false);
                _vm.LogLine($"CfAPI placeholders seeded: {n} under {AppPaths.SyncRootPath}");
            }
            catch (Exception ex)
            {
                // Soft: stay connected so Explorer can enumerate / FETCH_PLACEHOLDERS on demand.
                _vm.LogLine("CfAPI populate (soft): " + ex.Message.Replace('\n', ' '));
            }

            var probe = ProbeSyncRootListing();
            _vm.LogLine(probe);

            if (_provider.IsConnected && probe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
            {
                // Brief settle for shell after live connect — never before CfConnect.
                await Task.Delay(400, ct).ConfigureAwait(false);
                TryOpenSyncRootInExplorer(requireLiveProbe: true);
            }
            else
            {
                _vm.LogLine("CfAPI: skipping Explorer open — sync root not live/listable (avoid OS cloud dialog)");
            }

            var st = _provider.GetStatus();
            _vm.LogLine(
                "CfAPI Explorer connected — registered=" + st.Registered +
                " connected=" + st.Connected +
                " winrt=" + st.WinRtShell +
                " shell=" + (st.ShellRegistration ?? "?") +
                " path=" + AppPaths.SyncRootPath);
        }
        catch (Exception ex)
        {
            _vm.LogLine("CfAPI connect failed: " + ex.Message.Replace('\n', ' '));
            try { _provider?.Disconnect(); } catch { /* ignore */ }
            _vm.BindExplorerViewer(null);
            // Always scrub after a failed Register/Connect so Explorer never keeps a dead pin.
            if (registeredThisCall && _provider is not null)
            {
                try
                {
                    var scrub = _provider.CleanupOrphans("default");
                    _vm.LogLine("CfAPI hard-fail cleanup: " + scrub.Replace('\n', ' '));
                }
                catch { /* ignore */ }
            }
            throw;
        }
    }

    /// <summary>
    /// After unregister, a former placeholder root can still throw 0x8007016A on enum.
    /// Recreate a plain directory so Register/Connect start clean.
    /// </summary>
    private void EnsureFreshSyncRootDirectory()
    {
        var path = AppPaths.SyncRootPath;
        var parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent))
            Directory.CreateDirectory(parent);

        var needsRecreate = false;
        if (!Directory.Exists(path))
        {
            needsRecreate = true;
        }
        else
        {
            try
            {
                _ = Directory.EnumerateFileSystemEntries(path).Take(1).ToList();
                var attrs = File.GetAttributes(path);
                // ReparsePoint on the root after a bad unregister often means cloud residue.
                if (attrs.HasFlag(FileAttributes.ReparsePoint))
                    needsRecreate = true;
            }
            catch (Exception ex) when (IsCloudInvalid(ex))
            {
                needsRecreate = true;
                _vm.LogLine("CfAPI: SyncRoot not accessible (" + ShortEx(ex) + ") — recreating");
            }
            catch (Exception ex)
            {
                needsRecreate = true;
                _vm.LogLine("CfAPI: SyncRoot enum failed (" + ShortEx(ex) + ") — recreating");
            }
        }

        if (!needsRecreate)
        {
            Directory.CreateDirectory(path);
            return;
        }

        try
        {
            if (Directory.Exists(path))
            {
                var bak = path + "-dead-" + DateTime.UtcNow.ToString("HHmmssfff");
                try { Directory.Move(path, bak); }
                catch
                {
                    try { Directory.Delete(path, recursive: true); }
                    catch { /* best-effort */ }
                }
            }
        }
        catch (Exception ex)
        {
            _vm.LogLine("CfAPI: SyncRoot recreate move/delete: " + ShortEx(ex));
        }

        Directory.CreateDirectory(path);
        _vm.LogLine("CfAPI: SyncRoot recreated at " + path);
    }

    /// <summary>
    /// Directory listing probe — surfaces "cloud operation is invalid" (0x8007016A) in the UI log
    /// when the sync root is registered without a live CfConnect.
    /// </summary>
    private string ProbeSyncRootListing()
    {
        try
        {
            var entries = Directory.EnumerateFileSystemEntries(AppPaths.SyncRootPath).Take(20).ToList();
            return "CfAPI sync root OK — " + entries.Count + " entries under " + AppPaths.SyncRootPath;
        }
        catch (Exception ex)
        {
            return "CfAPI sync root LIST FAIL: " + ShortEx(ex);
        }
    }

    private void EnsureRegistered(string account)
    {
        if (_provider is null) return;
        if (_provider.GetStatus().Registered) return;
        try
        {
            _provider.RegisterSyncRoot(account);
            var st = _provider.GetStatus();
            _vm.LogLine(
                "CfAPI registered shell=" + (st.ShellRegistration ?? "?") +
                " winrt=" + st.WinRtShell +
                " id=" + (st.ShellSyncRootId ?? "?"));
        }
        catch (Exception first)
        {
            // Orphan / stale registration: tear down, refresh dir, retry once.
            _vm.LogLine("CfAPI register retry after: " + ShortEx(first));
            try { _provider.CleanupOrphans(account); } catch { /* ignore */ }
            try { _provider.Dispose(); } catch { /* ignore */ }
            EnsureFreshSyncRootDirectory();
            _provider = new CloudFilesProvider(AppPaths.SyncRootPath);
            _provider.RegisterSyncRoot(account);
            var st = _provider.GetStatus();
            _vm.LogLine(
                "CfAPI registered (retry) shell=" + (st.ShellRegistration ?? "?") +
                " winrt=" + st.WinRtShell +
                " id=" + (st.ShellSyncRootId ?? "?"));
        }
    }

    /// <summary>
    /// Open File Explorer at the sync root only when CfConnect is live and a probe list works.
    /// Never opens on 0x8007016A — that would surface the OS "Location is not available" dialog.
    /// </summary>
    public void TryOpenSyncRootInExplorer(bool requireLiveProbe = true)
    {
        if (_provider is null || !_provider.IsConnected)
        {
            _vm.LogLine("CfAPI: skip Explorer open — viewer not connected");
            return;
        }

        if (requireLiveProbe)
        {
            var probe = ProbeSyncRootListing();
            if (!probe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
            {
                _vm.LogLine("CfAPI: skip Explorer open — " + probe);
                return;
            }
        }

        try
        {
            Directory.CreateDirectory(AppPaths.SyncRootPath);
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = "\"" + AppPaths.SyncRootPath + "\"",
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            _vm.LogLine("open Explorer: " + ShortEx(ex));
        }
    }

    /// <summary>Disconnect + clear VM binding. Leaves sync root registered.</summary>
    public void Disconnect()
    {
        if (_vm.ExplorerViewer is not null)
            _vm.DisconnectExplorerViewer();
        else if (_provider is not null && _provider.IsConnected)
        {
            try { _provider.Disconnect(); } catch { /* ignore */ }
        }
    }

    /// <summary>Disconnect, unregister, dispose provider (process exit / explicit tear-down).</summary>
    public void Shutdown()
    {
        Disconnect();
        if (_provider is null) return;
        try { _provider.CleanupOrphans("default"); } catch { /* ignore */ }
        try { _provider.Dispose(); } catch { /* ignore */ }
        _provider = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Shutdown();
    }

    private static bool IsCloudInvalid(Exception ex)
    {
        for (var e = ex; e is not null; e = e.InnerException!)
        {
            if (e is IOException io && io.HResult == CloudOperationInvalidHResult)
                return true;
            if (e is COMException com && com.HResult == CloudOperationInvalidHResult)
                return true;
            var msg = e.Message ?? "";
            if (msg.Contains("cloud operation is invalid", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("0x8007016A", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("8007016A", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    private static string ShortEx(Exception ex) =>
        ex.Message.Replace('\n', ' ').Replace('\r', ' ');
}
