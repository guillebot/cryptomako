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

        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "tray.ico");
            if (File.Exists(iconPath))
                _tray.IconSource = new BitmapImage(new Uri(iconPath));
            else
                _tray.IconSource = new BitmapImage(new Uri("ms-appx:///Assets/tray.ico"));
        }
        catch
        {
            // Icon optional; menu still works.
        }

        _tray.LeftClickCommand = new RelayCommand(ShowMainWindow);
        _tray.ForceCreate();
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
        if (e.PropertyName == nameof(MainViewModel.IsUnlocked) && _vm is not null)
        {
            if (_vm.IsUnlocked)
                _mainWindow?.DispatcherQueue.TryEnqueue(() => _ = ConnectExplorerAfterUnlockAsync());
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
            _tray.ToolTipText = "CryptoMako — " + _vm.StatusTrayLabel;
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

    internal async Task ConnectExplorerAfterUnlockAsync()
    {
        if (_vm is null || _explorer is null || !_vm.IsUnlocked) return;
        if (_vm.IsExplorerViewerConnected) return;
        try
        {
            await _explorer.ConnectAsync();
        }
        catch (PlatformNotSupportedException)
        {
            // Soft viewer requires Windows Cloud Files.
        }
        catch (Exception ex)
        {
            // Soft CfAPI fail must NOT clear vault-unlocked (macOS soft Finder semantics).
            System.Diagnostics.Debug.WriteLine(ex);
        }
        RefreshTrayLabels();
        _mainWindow?.RefreshStatusStrip();
    }

    internal async Task ConnectExplorerManualAsync()
    {
        if (_vm is null || _explorer is null) return;
        if (!_vm.IsUnlocked)
            throw new InvalidOperationException("unlock vault first");
        await _explorer.ConnectAsync();
        RefreshTrayLabels();
        _mainWindow?.RefreshStatusStrip();
    }

    internal void DisconnectExplorerManual()
    {
        _explorer?.Disconnect();
        RefreshTrayLabels();
        _mainWindow?.RefreshStatusStrip();
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
