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
            // ALWAYS hard-recreate the sync-root directory. Leftover reparse/placeholder
            // state from a prior Register is a common source of live 0x8007016A even after CfConnect.
            HardRecreateSyncRootDirectory();
            _provider = new CloudFilesProvider(AppPaths.SyncRootPath);

            // AttachSession BEFORE Register/Connect. WinRT Register creates a NameSpace pin and
            // Explorer may FETCH_PLACEHOLDERS immediately; a null Session fail-closes with
            // ACCESS_DENIED and poisons the root (Location is not available / cloud invalid)
            // for the rest of the process lifetime.
            _provider.AttachSession(_vm.Session);

            // Register then CfConnect with no await in between (minimize shell race).
            EnsureRegistered("default");
            registeredThisCall = true;

            _provider.Connect();
            if (!_provider.IsConnected)
                throw new InvalidOperationException("CfConnectSyncRoot did not leave the provider connected");

            _vm.BindExplorerViewer(_provider);

            try
            {
                var n = await _provider.PopulateRootPlaceholdersAsync(recursive: true, ct: ct)
                    .ConfigureAwait(false);
                _vm.LogLine($"CfAPI placeholders seeded: {n} under {AppPaths.SyncRootPath}");
                // Re-enable on-demand population on the root so Explorer FETCH_PLACEHOLDERS
                // still fires after soft seed (and recovers if a prior empty TRANSFER disabled it).
                // Do NOT CfUpdatePlaceholder the sync root (0x8007016A / "cloud operation is invalid").
                if (n == 0)
                {
                    try
                    {
                        var refreshed = await _provider.RefreshDirectoryAsync("/", ct).ConfigureAwait(false);
                        _vm.LogLine($"CfAPI root refresh placeholders: {refreshed}");
                    }
                    catch (Exception rex)
                    {
                        _vm.LogLine("CfAPI root refresh (soft): " + rex.Message.Replace("\n", " "));
                    }
                }
            }
            catch (Exception ex)
            {
                // Soft: stay connected so Explorer can enumerate / FETCH_PLACEHOLDERS on demand.
                _vm.LogLine("CfAPI populate (soft): " + ex.Message.Replace("\n", " "));
            }

            var probe = ProbeSyncRootListing();
            _vm.LogLine(probe);
            var xprobe = await ProbeCrossProcessListingWithRetryAsync(ct).ConfigureAwait(false);
            _vm.LogLine(xprobe);

            if (!_provider.IsConnected
                || !probe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal)
                || !xprobe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
            {
                // In-proc OK but cross-process FAIL is the Desktop?Explorer failure mode.
                // Scrub so Explorer never keeps a dead pin.
                _vm.LogLine("CfAPI: sync root not listable after Connect ? scrubbing registration (avoid dead pin)");
                try { _provider.Disconnect(); } catch { /* ignore */ }
                _vm.BindExplorerViewer(null);
                try
                {
                    var scrubFail = _provider.CleanupOrphans("default");
                    _vm.LogLine("CfAPI unlistable cleanup: " + scrubFail.Replace('\n', ' '));
                }
                catch { /* ignore */ }
                throw new InvalidOperationException(
                    "CfAPI sync root not listable after Connect: inproc=[" + probe + "] xproc=[" + xprobe + "]");
            }

            // Re-probe after a short settle ? never open Explorer on a still-invalid root.
            await Task.Delay(500, ct).ConfigureAwait(false);
            var probe2 = ProbeSyncRootListing();
            var xprobe2 = await ProbeCrossProcessListingWithRetryAsync(ct).ConfigureAwait(false);
            _vm.LogLine("CfAPI re-probe before Explorer open: " + probe2);
            _vm.LogLine("CfAPI re-probe cross-process: " + xprobe2);
            if (probe2.StartsWith("CfAPI sync root OK", StringComparison.Ordinal)
                && xprobe2.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
                TryOpenSyncRootInExplorer(requireLiveProbe: true);
            else
            {
                _vm.LogLine("CfAPI: re-probe failed ? scrubbing (avoid OS cloud dialog)");
                try { _provider.Disconnect(); } catch { /* ignore */ }
                _vm.BindExplorerViewer(null);
                try { _provider.CleanupOrphans("default"); } catch { /* ignore */ }
                throw new InvalidOperationException(
                    "CfAPI sync root re-probe failed: inproc=[" + probe2 + "] xproc=[" + xprobe2 + "]");
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
    /// <summary>
    /// Always move aside any existing SyncRoot and create a plain new directory.
    /// Conditional recreate was insufficient: a live WinRT root can still ENUM-fail with
    /// 0x8007016A while Desktop holds CfConnect if the folder carries poisoned placeholder state.
    /// </summary>
    private void HardRecreateSyncRootDirectory()
    {
        var path = AppPaths.SyncRootPath;
        var parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent))
            Directory.CreateDirectory(parent);

        try
        {
            if (Directory.Exists(path) || File.Exists(path))
            {
                var bak = path + "-dead-" + DateTime.UtcNow.ToString("HHmmssfff");
                try { Directory.Move(path, bak); }
                catch
                {
                    try { Directory.Delete(path, recursive: true); }
                    catch (Exception ex)
                    {
                        _vm.LogLine("CfAPI: SyncRoot hard-delete: " + ShortEx(ex));
                    }
                }
            }
        }
        catch (Exception ex)
        {
            _vm.LogLine("CfAPI: SyncRoot hard-recreate move: " + ShortEx(ex));
        }

        Directory.CreateDirectory(path);
        // Verify plain (no cloud invalid) before Register.
        try
        {
            _ = Directory.EnumerateFileSystemEntries(path).Take(1).ToList();
            var attrs = File.GetAttributes(path);
            if (attrs.HasFlag(FileAttributes.ReparsePoint))
                throw new IOException("SyncRoot still has ReparsePoint after recreate");
            _vm.LogLine("CfAPI: SyncRoot hard-recreated (plain) at " + path);
        }
        catch (Exception ex)
        {
            _vm.LogLine("CfAPI: SyncRoot plain-check failed: " + ShortEx(ex));
            throw;
        }
    }

    /// <summary>Alias used by register-retry path — always hard-recreate.</summary>
    private void EnsureFreshSyncRootDirectory() => HardRecreateSyncRootDirectory();

    /// <summary>
    /// Directory listing probe — surfaces "cloud operation is invalid" (0x8007016A) in the UI log
    /// when the sync root is registered without a live CfConnect.
    /// </summary>
    private string ProbeSyncRootListing()
    {
        try
        {
            var entries = Directory.EnumerateFileSystemEntries(AppPaths.SyncRootPath).Take(20).ToList();
            // Empty can be a legit empty vault, but with a live provider it must still ENUM
            // without 0x8007016A. Callers gate Explorer open on the OK prefix.
            return "CfAPI sync root OK — " + entries.Count + " entries under " + AppPaths.SyncRootPath
                + (entries.Count == 0 ? " (empty)" : " sample=[" + string.Join(", ", entries.Select(Path.GetFileName).Take(5)) + "]");
        }
        catch (Exception ex)
        {
            if (IsCloudInvalid(ex))
                return "CfAPI sync root LIST FAIL (0x8007016A cloud invalid): " + ShortEx(ex);
            return "CfAPI sync root LIST FAIL: " + ShortEx(ex);
        }
    }

    /// <summary>
    /// Out-of-process directory enum ? the real Explorer/cmd path. In-process enum can succeed
    /// while other processes still get 0x8007016A if SyncRoot FETCH TRANSFER poisons the root.
    /// </summary>
    private async Task<string> ProbeCrossProcessListingWithRetryAsync(CancellationToken ct)
    {
        string last = ProbeCrossProcessListing();
        if (last.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
            return last;
        for (var i = 0; i < 3; i++)
        {
            await Task.Delay(400, ct).ConfigureAwait(false);
            last = ProbeCrossProcessListing();
            if (last.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
                return last;
        }
        return last;
    }

    private string ProbeCrossProcessListing()
    {
        var path = AppPaths.SyncRootPath;
        try
        {
            // Prefer cmd.exe ? nested PowerShell -Command quoting is fragile under WinUI.
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/d /c dir /b \"" + path + "\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var proc = Process.Start(psi);
            if (proc is null)
                return "CfAPI sync root LIST FAIL (cross-process): failed to start cmd";
            var stdout = proc.StandardOutput.ReadToEnd();
            var stderr = proc.StandardError.ReadToEnd();
            if (!proc.WaitForExit(15000))
            {
                try { proc.Kill(entireProcessTree: true); } catch { /* ignore */ }
                return "CfAPI sync root LIST FAIL (cross-process): cmd timeout";
            }
            var err = (stderr ?? "").Trim();
            var outTrim = (stdout ?? "").Trim();
            if (proc.ExitCode == 0)
            {
                var names = outTrim.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                return "CfAPI sync root OK (cross-process) ? " + names.Length
                    + " sample=[" + string.Join(", ", names.Take(5)) + "]";
            }
            var combined = (outTrim + " " + err).Trim();
            if (combined.Contains("cloud operation is invalid", StringComparison.OrdinalIgnoreCase)
                || combined.Contains("0x8007016A", StringComparison.OrdinalIgnoreCase)
                || combined.Contains("File Not Found", StringComparison.OrdinalIgnoreCase))
                return "CfAPI sync root LIST FAIL (cross-process 0x8007016A): " + combined;
            return "CfAPI sync root LIST FAIL (cross-process): exit=" + proc.ExitCode + " " + combined;
        }
        catch (Exception ex)
        {
            if (IsCloudInvalid(ex))
                return "CfAPI sync root LIST FAIL (cross-process 0x8007016A): " + ShortEx(ex);
            return "CfAPI sync root LIST FAIL (cross-process): " + ShortEx(ex);
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
            var xprobe = ProbeCrossProcessListing();
            if (!probe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal)
                || !xprobe.StartsWith("CfAPI sync root OK", StringComparison.Ordinal))
            {
                _vm.LogLine("CfAPI: skip Explorer open ? inproc=[" + probe + "] xproc=[" + xprobe + "]");
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
