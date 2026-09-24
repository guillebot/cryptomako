using System.ComponentModel;
using CryptoMako.App;
using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace CryptoMako.Desktop;

public partial class App : Application
{
    private MainViewModel? _vm;
    private ExplorerViewerController? _explorer;
    private MainWindow? _mainWindow;
    private TaskbarIcon? _tray;
    private MenuFlyoutItem? _trayStatusItem;
    private MenuFlyoutItem? _trayLampsItem;
    private bool _isQuitting;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            System.Diagnostics.Debug.WriteLine(e.Exception);
            e.Handled = true;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _vm = new MainViewModel();
        _explorer = new ExplorerViewerController(_vm);
        _mainWindow = new MainWindow(_vm);
        InstallTray();
        _vm.PropertyChanged += OnVmPropertyChanged;
        RefreshTrayLabels();
        _mainWindow.Activate();
        _ = _vm.InitializeConnectivityAsync();
    }

    internal MainViewModel? ViewModel => _vm;
    internal bool IsQuitting => _isQuitting;

    private void InstallTray()
    {
        _trayStatusItem = new MenuFlyoutItem { Text = "Status: locked", IsEnabled = false };
        _trayLampsItem = new MenuFlyoutItem { Text = "Probe: not probed", IsEnabled = false };

        var menu = new MenuFlyout();
        menu.Items.Add(MakeItem("Open CryptoMako", ShowMainWindow));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MakeItem("Unlock", () => _ = TrayUnlockAsync()));
        menu.Items.Add(MakeItem("Lock", () => _ = TrayLockAsync()));
        menu.Items.Add(MakeItem("Probe S3", () => _ = TrayProbeAsync()));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(_trayStatusItem);
        menu.Items.Add(_trayLampsItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MakeItem("Quit", Quit));

        _tray = new TaskbarIcon
        {
            ToolTipText = "CryptoMako",
            ContextFlyout = menu,
            MenuActivation = H.NotifyIcon.Core.PopupActivationMode.LeftOrRightClick,
        };

        // Unpackaged host: never use ms-appx:/// — missing packaged resource maps to
        // COM 0x80070002 (FILE_NOT_FOUND) and can tear down the process after Activate.
        try
        {
            var assets = Path.Combine(AppContext.BaseDirectory, "Assets");
            var ico = Path.Combine(assets, "tray.ico");
            var png = Path.Combine(assets, "tray-windows.png");
            if (File.Exists(ico))
                _tray.IconSource = new BitmapImage(new Uri(ico));
            else if (File.Exists(png))
                _tray.IconSource = new BitmapImage(new Uri(png));
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine("tray icon: " + ex);
        }

        _tray.LeftClickCommand = new RelayCommand(ShowMainWindow);
        try
        {
            _tray.ForceCreate();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine("tray ForceCreate: " + ex);
            try { _tray.Dispose(); } catch { /* ignore */ }
            _tray = null;
        }
    }

    private static MenuFlyoutItem MakeItem(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.Status)
            or nameof(MainViewModel.LastProbe)
            or nameof(MainViewModel.IsUnlocked)
            or nameof(MainViewModel.Busy)
            or nameof(MainViewModel.StatusTrayLabel)
            or nameof(MainViewModel.ProbeTrayLabel)
            or nameof(MainViewModel.IsExplorerViewerConnected)
            or nameof(MainViewModel.ExplorerViewer))
        {
            _mainWindow?.DispatcherQueue.TryEnqueue(RefreshTrayLabels);
            _mainWindow?.DispatcherQueue.TryEnqueue(() => _mainWindow?.RefreshStatusStrip());
        }

        // Soft parity with macOS Finder mount: bind CfAPI viewer after unlock; Lock disconnects via VM.
        // After Lock, also scrub registration so Explorer never keeps a dead CryptoMako pin
        // ("The cloud operation is invalid" / 0x8007016A). Unlock re-registers + CfConnects.
        if (e.PropertyName == nameof(MainViewModel.IsUnlocked) && _vm is not null)
        {
            if (_vm.IsUnlocked)
                _mainWindow?.DispatcherQueue.TryEnqueue(() => _ = ConnectExplorerAfterUnlockAsync());
            else
                _mainWindow?.DispatcherQueue.TryEnqueue(ScrubExplorerAfterLock);
        }
    }

    private void RefreshTrayLabels()
    {
        if (_vm is null) return;
        if (_trayStatusItem is not null)
            _trayStatusItem.Text = "Status: " + _vm.StatusTrayLabel;
        if (_trayLampsItem is not null)
            _trayLampsItem.Text = "Probe: " + _vm.ProbeTrayLabel;
        if (_tray is not null)
            _tray.ToolTipText = "CryptoMako â€” " + _vm.StatusTrayLabel;
    }

    internal void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.RestoreFromTray();
    }

    private async Task TrayUnlockAsync()
    {
        try { if (_vm is not null) await _vm.UnlockAsync(); }
        catch { /* VM logs */ }
        RefreshTrayLabels();
    }

    private async Task TrayLockAsync()
    {
        try { if (_vm is not null) await _vm.LockAsync(); }
        catch { /* ignore */ }
        RefreshTrayLabels();
    }

    private async Task TrayProbeAsync()
    {
        try { if (_vm is not null) await _vm.ProbeAsync(); }
        catch { /* VM logs */ }
        RefreshTrayLabels();
    }

    /// <summary>
    /// Lock High already disconnected the provider; unregister so Explorer sidebar has no dead pin.
    /// Soft CfAPI scrub must not clear vault-unlocked (already locked) or wipe CredMan.
    /// </summary>
    internal void ScrubExplorerAfterLock()
    {
        try { _explorer?.Disconnect(); } catch { /* ignore */ }
        try
        {
            // Shutdown unregisters + disposes; next Unlock constructs a fresh connect cycle.
            _explorer?.Shutdown();
            _explorer = _vm is null ? null : new ExplorerViewerController(_vm);
            _vm?.LogLine("CfAPI Lock scrub: unregistered sync root (no dead Explorer pin)");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine(ex);
            _vm?.LogLine("CfAPI Lock scrub: " + ex.Message.Replace('\n', ' '));
        }
        RefreshTrayLabels();
        _mainWindow?.DispatcherQueue.TryEnqueue(() => _mainWindow?.RefreshStatusStrip());
    }

    internal async Task ConnectExplorerAfterUnlockAsync()
    {
        if (_vm is null || _explorer is null || !_vm.IsUnlocked) return;
        if (_vm.IsExplorerViewerConnected) return;
        try
        {
            await _explorer.ConnectAsync();
        }
        catch (PlatformNotSupportedException ex)
        {
            // Soft viewer requires Windows Cloud Files.
            _vm.LogLine("CfAPI not available: " + ex.Message.Replace('\n', ' '));
        }
        catch (Exception ex)
        {
            // Soft CfAPI fail must NOT clear vault-unlocked (macOS soft Finder semantics).
            _vm.LogLine("CfAPI connect (soft): " + ex.Message.Replace('\n', ' '));
            System.Diagnostics.Debug.WriteLine(ex);
        }
        RefreshTrayLabels();
        _mainWindow?.DispatcherQueue.TryEnqueue(() => _mainWindow?.RefreshStatusStrip());
    }

    internal async Task ConnectExplorerManualAsync()
    {
        if (_vm is null || _explorer is null) return;
        if (!_vm.IsUnlocked)
            throw new InvalidOperationException("unlock vault first");
        await _explorer.ConnectAsync();
        RefreshTrayLabels();
        _mainWindow?.DispatcherQueue.TryEnqueue(() => _mainWindow?.RefreshStatusStrip());
    }

    internal void DisconnectExplorerManual()
    {
        // Same as Lock scrub: registered-but-disconnected roots make Explorer show
        // 0x8007016A ("The cloud operation is invalid") on the sidebar pin.
        try { _explorer?.Disconnect(); } catch { /* ignore */ }
        try
        {
            _explorer?.Shutdown();
            _explorer = _vm is null ? null : new ExplorerViewerController(_vm);
            _vm?.LogLine("CfAPI Explorer disconnected + unregistered (no dead Explorer pin)");
        }
        catch (Exception ex)
        {
            _vm?.LogLine("CfAPI disconnect scrub: " + ex.Message.Replace('\n', ' '));
        }
        RefreshTrayLabels();
        _mainWindow?.DispatcherQueue.TryEnqueue(() => _mainWindow?.RefreshStatusStrip());
    }

    /// <summary>Open sync-root folder in File Explorer when connected (badge / Open link).</summary>
    internal void OpenExplorerSyncRoot()
    {
        if (_explorer is null || _vm is null) return;
        if (!_vm.IsExplorerViewerConnected)
        {
            _vm.LogLine("Explorer viewer not connected â€” unlock + Connect Explorer first");
            return;
        }
        _explorer.TryOpenSyncRootInExplorer();
    }

    internal void Quit()
    {
        _isQuitting = true;
        try { _tray?.Dispose(); } catch { /* ignore */ }
        _tray = null;
        _ = ShutdownAsync();
    }

    private async Task ShutdownAsync()
    {
        try
        {
            if (_vm is not null)
                await _vm.DisposeAsync();
        }
        catch { /* ignore */ }
        try { _explorer?.Dispose(); } catch { /* ignore */ }
        _mainWindow?.CloseForQuit();
        Exit();
    }

    private sealed class RelayCommand : System.Windows.Input.ICommand
    {
        private readonly Action _action;
        public RelayCommand(Action action) => _action = action;
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => _action();
#pragma warning disable CS0067
        public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
    }
}
