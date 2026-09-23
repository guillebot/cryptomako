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

    /// <summary>
    /// Register (if needed), Connect, attach the unlocked session, seed root placeholders,
    /// and bind <see cref="MainViewModel.ExplorerViewer"/>.
    /// </summary>
    public async Task ConnectAsync(CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_vm.Session is null)
            throw new InvalidOperationException("unlock vault before connecting Explorer viewer");

        _provider ??= new CloudFilesProvider(AppPaths.SyncRootPath);

        if (!_provider.IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI Explorer viewer requires Windows 10 1803+.");

        try
        {
            Directory.CreateDirectory(AppPaths.SyncRootPath);
            try { _provider.RegisterSyncRoot("default"); }
            catch { /* already registered */ }

            if (!_provider.IsConnected)
                _provider.Connect();

            _provider.AttachSession(_vm.Session);
            _ = await _provider.PopulateRootPlaceholdersAsync(recursive: false, ct: ct).ConfigureAwait(true);
            _vm.BindExplorerViewer(_provider);
        }
        catch
        {
            try { _provider.Disconnect(); } catch { /* ignore */ }
            _vm.BindExplorerViewer(null);
            throw;
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
