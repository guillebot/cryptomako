using System.Diagnostics;
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
    private readonly MainViewModel _vm;
    private CloudFilesProvider? _provider;
    private bool _disposed;

    public ExplorerViewerController(MainViewModel vm) => _vm = vm;

    public bool IsConnected => _provider?.IsConnected == true;

    public string SyncRootPath => AppPaths.SyncRootPath;

    /// <summary>
    /// Register (if needed), Connect, attach the unlocked session, seed root placeholders,
    /// and bind <see cref="MainViewModel.ExplorerViewer"/>.
    /// Populate failures are soft (log only) so a live CfConnect is not torn down — a
    /// registered-but-disconnected sync root makes Explorer show "cloud operation is invalid".
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
            Directory.CreateDirectory(AppPaths.SyncRootPath);
            EnsureRegistered("default");
            registeredThisCall = true;

            if (!_provider.IsConnected)
                _provider.Connect();

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

            TryOpenSyncRootInExplorer();
            _vm.LogLine("CfAPI Explorer connected — " + AppPaths.SyncRootPath);
        }
        catch
        {
            try { _provider.Disconnect(); } catch { /* ignore */ }
            _vm.BindExplorerViewer(null);
            // Avoid leaving a registered-but-disconnected orphan (Explorer "cloud operation is invalid").
            if (registeredThisCall && _provider is not null && !_provider.IsConnected)
            {
                try { _provider.UnregisterSyncRoot("default"); } catch { /* ignore */ }
            }
            throw;
        }
    }

    private void EnsureRegistered(string account)
    {
        if (_provider is null) return;
        if (_provider.GetStatus().Registered) return;
        try
        {
            _provider.RegisterSyncRoot(account);
        }
        catch (Exception first)
        {
            // Orphan / stale registration: tear down and retry once.
            _vm.LogLine("CfAPI register retry after: " + first.Message.Replace('\n', ' '));
            try { _provider.UnregisterSyncRoot(account); } catch { /* ignore */ }
            try { _provider.Dispose(); } catch { /* ignore */ }
            _provider = new CloudFilesProvider(AppPaths.SyncRootPath);
            _provider.RegisterSyncRoot(account);
        }
    }

    /// <summary>Open File Explorer at the sync root (macOS Finder reveal parity).</summary>
    public void TryOpenSyncRootInExplorer()
    {
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
            _vm.LogLine("open Explorer: " + ex.Message.Replace('\n', ' '));
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
        try { _provider.UnregisterSyncRoot("default"); } catch { /* ignore */ }
        try { _provider.Dispose(); } catch { /* ignore */ }
        _provider = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Shutdown();
    }
}
