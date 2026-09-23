using System;
using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using CryptoMako.App;

namespace CryptoMako.Desktop;

public partial class App : Application
{
    private MainViewModel? _vm;
    private MainWindow? _mainWindow;
    private TrayIcon? _tray;
    private NativeMenuItem? _trayStatusItem;
    private NativeMenuItem? _trayLampsItem;

    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _vm = new MainViewModel();
            _mainWindow = new MainWindow { DataContext = _vm };
            desktop.MainWindow = _mainWindow;
            desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            desktop.Exit += async (_, _) =>
            {
                if (_vm is not null)
                    await _vm.DisposeAsync();
                _tray?.Dispose();
            };

            InstallTray();
            _vm.PropertyChanged += OnVmPropertyChanged;
            RefreshTrayLabels();
            _ = _vm.InitializeConnectivityAsync();
        }

        base.OnFrameworkInitializationCompleted();
    }

    private void InstallTray()
    {
        _trayStatusItem = new NativeMenuItem("Status: locked") { IsEnabled = false };
        _trayLampsItem = new NativeMenuItem("Probe: not probed") { IsEnabled = false };

        var menu = new NativeMenu();
        menu.Items.Add(new NativeMenuItem("Open CryptoMako") { Command = new SimpleCommand(ShowMainWindow) });
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(new NativeMenuItem("Unlock") { Command = new SimpleCommand(() => _ = TrayUnlockAsync()) });
        menu.Items.Add(new NativeMenuItem("Lock") { Command = new SimpleCommand(() => _ = TrayLockAsync()) });
        menu.Items.Add(new NativeMenuItem("Probe S3") { Command = new SimpleCommand(() => _ = TrayProbeAsync()) });
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(_trayStatusItem);
        menu.Items.Add(_trayLampsItem);
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(new NativeMenuItem("Quit") { Command = new SimpleCommand(Quit) });

        _tray = new TrayIcon
        {
            ToolTipText = "CryptoMako",
            IsVisible = true,
            Menu = menu,
        };
        try
        {
            var uri = new Uri("avares://CryptoMako.Desktop/Assets/tray.png");
            using var stream = AssetLoader.Open(uri);
            _tray.Icon = new WindowIcon(stream);
        }
        catch
        {
            // Icon optional; menu still works.
        }

        _tray.Clicked += (_, _) => ShowMainWindow();

        // Keep the tray icon alive for the app lifetime.
        var icons = new TrayIcons { _tray };
        TrayIcon.SetIcons(this, icons);
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(MainViewModel.Status)
            or nameof(MainViewModel.LastProbe)
            or nameof(MainViewModel.IsUnlocked)
            or nameof(MainViewModel.Busy)
            or nameof(MainViewModel.StatusTrayLabel)
            or nameof(MainViewModel.ProbeTrayLabel))
        {
            Dispatcher.UIThread.Post(RefreshTrayLabels);
        }
    }

    private void RefreshTrayLabels()
    {
        if (_vm is null) return;
        if (_trayStatusItem is not null)
            _trayStatusItem.Header = "Status: " + _vm.StatusTrayLabel;
        if (_trayLampsItem is not null)
            _trayLampsItem.Header = "Probe: " + _vm.ProbeTrayLabel;
        if (_tray is not null)
            _tray.ToolTipText = "CryptoMako — " + _vm.StatusTrayLabel;
    }

    private void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private async System.Threading.Tasks.Task TrayUnlockAsync()
    {
        try { if (_vm is not null) await _vm.UnlockAsync(); }
        catch { /* VM logs */ }
        RefreshTrayLabels();
    }

    private async System.Threading.Tasks.Task TrayLockAsync()
    {
        try { if (_vm is not null) await _vm.LockAsync(); }
        catch { /* ignore */ }
        RefreshTrayLabels();
    }

    private async System.Threading.Tasks.Task TrayProbeAsync()
    {
        try { if (_vm is not null) await _vm.ProbeAsync(); }
        catch { /* VM logs */ }
        RefreshTrayLabels();
    }

    private void Quit()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
            desktop.Shutdown();
    }

    private sealed class SimpleCommand : System.Windows.Input.ICommand
    {
        private readonly Action _action;
        public SimpleCommand(Action action) => _action = action;
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => _action();
#pragma warning disable CS0067
        public event EventHandler? CanExecuteChanged;
#pragma warning restore CS0067
    }
}
