using System.ComponentModel;
using CryptoMako.App;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using Windows.UI;
using WinRT.Interop;

namespace CryptoMako.Desktop;

public sealed partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private readonly AppWindow _appWindow;
    private bool _forceClose;
    private bool _syncingUi;

    public MainWindow(MainViewModel vm)
    {
        _vm = vm;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;

        var hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        _appWindow.Title = "CryptoMako";
        _appWindow.Resize(new Windows.Graphics.SizeInt32(860, 680));
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
            if (File.Exists(iconPath))
                _appWindow.SetIcon(iconPath);
        }
        catch { /* optional */ }

        _appWindow.Closing += OnAppWindowClosing;
        _appWindow.Changed += OnAppWindowChanged;

        LoadFromVm();
        _vm.PropertyChanged += OnVmPropertyChanged;
        RefreshStatusStrip();
    }

    internal void RefreshStatusStrip()
    {
        if (_syncingUi) return;
        VaultStateText.Text = "Vault: " + _vm.StatusTrayLabel;
        StatusBarText.Text = _vm.Status;
        RemoteHintText.Text = _vm.RemoteChangeHint;
        BackupRemoteHintText.Text = _vm.RemoteChangeHint;
        LogBox.Text = _vm.Log;
        BackupSourcesBox.Text = _vm.BackupSourcesSummary;
        StorageModeText.Text = _vm.Settings.StorageMode;

        SetLamp(LampDns, _vm.LastProbe?.Dns ?? ProbeLamp.Unknown);
        SetLamp(LampTcp, _vm.LastProbe?.Tcp ?? ProbeLamp.Unknown);
        SetLamp(LampHttps, _vm.LastProbe?.Https ?? ProbeLamp.Unknown);
        SetLamp(LampList, _vm.LastProbe?.List ?? ProbeLamp.Unknown);

        if (_vm.IsExplorerViewerConnected)
        {
            ExplorerBadgeText.Text = "Explorer: connected";
            ExplorerBadge.Background = new SolidColorBrush(Color.FromArgb(255, 20, 140, 80));
            ExplorerPathLink.Content = "Open " + AppPaths.SyncRootPath;
        }
        else
        {
            ExplorerBadgeText.Text = "Explorer: off";
            ExplorerBadge.Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"];
            ExplorerPathLink.Content = "Open sync root";
        }

        RefreshBackupProgressUi();
    }

    private void RefreshBackupProgressUi()
    {
        var visible = _vm.IsBackupSyncRunning
                      || !string.IsNullOrEmpty(_vm.BackupPhase)
                      || _vm.BackupProgressPercent > 0;
        BackupProgressPanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        BackupProgressBar.Value = _vm.BackupProgressPercent;
        BackupProgressLabelText.Text = string.IsNullOrEmpty(_vm.BackupProgressLabel)
            ? (_vm.IsBackupSyncRunning ? "Syncingâ€¦" : "")
            : _vm.BackupProgressLabel;
        BackupSpeedText.Text = string.IsNullOrEmpty(_vm.BackupSpeedLabel) ? "" : ("Speed: " + _vm.BackupSpeedLabel);
        BackupEtaText.Text = _vm.BackupEtaLabel ?? "";
        BackupCurrentPathText.Text = _vm.BackupCurrentPath ?? "";
        if (_vm.BackupPhase is "done" or "cancelled" or "error")
        {
            // Keep panel visible with final status; hide after next idle refresh if cleared.
        }
    }

    private static void SetLamp(Microsoft.UI.Xaml.Shapes.Ellipse lamp, ProbeLamp state)
    {
        lamp.Fill = new SolidColorBrush(state switch
        {
            ProbeLamp.Ok => Color.FromArgb(255, 40, 180, 90),
            ProbeLamp.Fail => Color.FromArgb(255, 220, 60, 60),
            ProbeLamp.Skip => Color.FromArgb(255, 140, 140, 140),
            _ => Color.FromArgb(255, 100, 100, 100),
        });
    }

    private void LoadFromVm()
    {
        _syncingUi = true;
        try
        {
            LocalVaultPathBox.Text = _vm.Settings.LocalVaultPath ?? "";
            EndpointBox.Text = _vm.Settings.Endpoint ?? "";
            RegionBox.Text = _vm.Settings.Region ?? "";
            BucketBox.Text = _vm.Settings.Bucket ?? "";
            PrefixBox.Text = _vm.Settings.Prefix ?? "";
            AccessKeyBox.Text = _vm.Settings.AccessKey ?? "";
            PathStyleCheck.IsChecked = _vm.Settings.PathStyle;
            AutoReconnectCheck.IsChecked = _vm.Settings.AutoReconnect;
            BackupSourceBox.Text = _vm.BackupSource ?? "";
            VaultFolderBox.Text = _vm.VaultFolder ?? "";

            ProxyModeBox.Text = _vm.Preferences.ProxyMode ?? "";
            ProxyHostBox.Text = _vm.Preferences.ProxyHost ?? "";
            ProxyPortBox.Text = _vm.Preferences.ProxyPort.ToString();
            ProxyUserBox.Text = _vm.Preferences.ProxyUsername ?? "";
            LimitUploadCheck.IsChecked = _vm.Preferences.LimitSyncUploadBandwidth;
            UploadCapBox.Text = _vm.Preferences.SyncUploadCapMbps.ToString();
            WorkersSBox.Text = _vm.Preferences.SyncSmallPutConcurrency.ToString();
            WorkersMBox.Text = _vm.Preferences.SyncMediumPutConcurrency.ToString();
            WorkersLBox.Text = _vm.Preferences.SyncLargePutConcurrency.ToString();
        }
        finally
        {
            _syncingUi = false;
        }
        ApplyStorageModeUi();
        ApplyProxyModeUi();
        RefreshStatusStrip();
    }

    private void PushToVm()
    {
        // Mirror proxy radios into the hidden ProxyModeBox before reading prefs.
        if (ProxyCustomRadio?.IsChecked == true)
            ProxyModeBox.Text = "custom";
        else if (ProxyOffRadio?.IsChecked == true)
            ProxyModeBox.Text = "direct";
        else if (ProxySystemRadio?.IsChecked == true)
            ProxyModeBox.Text = "system";

        _vm.Settings.LocalVaultPath = LocalVaultPathBox.Text ?? "";
        _vm.Settings.Endpoint = EndpointBox.Text ?? "";
        _vm.Settings.Region = RegionBox.Text ?? "";
        _vm.Settings.Bucket = BucketBox.Text ?? "";
        _vm.Settings.Prefix = PrefixBox.Text ?? "";
        _vm.Settings.AccessKey = AccessKeyBox.Text ?? "";
        _vm.Settings.PathStyle = PathStyleCheck.IsChecked == true;
        _vm.Settings.AutoReconnect = AutoReconnectCheck.IsChecked == true;
        _vm.BackupSource = BackupSourceBox.Text ?? "";
        _vm.VaultFolder = VaultFolderBox.Text ?? "";

        _vm.Preferences.ProxyMode = ProxyModeBox.Text ?? "";
        _vm.Preferences.ProxyHost = ProxyHostBox.Text ?? "";
        if (int.TryParse(ProxyPortBox.Text, out var port))
            _vm.Preferences.ProxyPort = port;
        _vm.Preferences.ProxyUsername = ProxyUserBox.Text ?? "";
        _vm.Preferences.LimitSyncUploadBandwidth = LimitUploadCheck.IsChecked == true;
        if (double.TryParse(UploadCapBox.Text, out var mbps))
            _vm.Preferences.SyncUploadCapMbps = mbps;
        if (int.TryParse(WorkersSBox.Text, out var s))
            _vm.Preferences.SyncSmallPutConcurrency = s;
        if (int.TryParse(WorkersMBox.Text, out var m))
            _vm.Preferences.SyncMediumPutConcurrency = m;
        if (int.TryParse(WorkersLBox.Text, out var l))
            _vm.Preferences.SyncLargePutConcurrency = l;
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(RefreshStatusStrip);
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_forceClose) return;
        if (Application.Current is App { IsQuitting: true }) return;
        args.Cancel = true;
        HideToTray();
    }

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidPresenterChange) return;
        if (_appWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized })
            HideToTray();
    }

    private void HideToTray()
    {
        try { _appWindow.Hide(); }
        catch { /* ignore */ }
    }

    internal void RestoreFromTray()
    {
        try
        {
            if (_appWindow.Presenter is OverlappedPresenter op)
                op.Restore();
            _appWindow.Show();
            Activate();
        }
        catch { Activate(); }
    }

    internal void CloseForQuit()
    {
        _forceClose = true;
        try { Close(); } catch { /* ignore */ }
    }

    private void OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        _vm.Password = PasswordBox.Password ?? "";
    }

    private void OnModeLocal(object sender, RoutedEventArgs e)
    {
        PushToVm();
        _vm.Settings.StorageMode = "local";
        _vm.SaveSettings();
        StorageModeText.Text = _vm.Settings.StorageMode;
        ApplyStorageModeUi();
        UiNote("Storage mode: local");
    }

    private void OnModeS3(object sender, RoutedEventArgs e)
    {
        PushToVm();
        _vm.Settings.StorageMode = "s3";
        _vm.SaveSettings();
        StorageModeText.Text = _vm.Settings.StorageMode;
        ApplyStorageModeUi();
        UiNote("Storage mode: s3");
    }

    private async void OnSaveSettings(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            _vm.SaveSettings();
            // Endpoint/settings change: refresh lamps immediately (monitor continues ~20s).
            await _vm.ProbeAsync();
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnAutoReconnectClick(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            await _vm.OnAutoReconnectChangedAsync();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnSavePassword(object sender, RoutedEventArgs e)
    {
        try
        {
            _vm.Password = PasswordBox.Password ?? "";
            _vm.SavePasswordToStore();
            PasswordBox.Password = "";
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnUnlock(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            _vm.Password = PasswordBox.Password ?? "";
            await _vm.UnlockAsync();
            PasswordBox.Password = "";
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnLock(object sender, RoutedEventArgs e)
    {
        try { await _vm.LockAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnProbe(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            await _vm.ProbeAsync();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnSync(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            if (!_vm.IsUnlocked)
                throw new InvalidOperationException("unlock vault first — Sync needs an unlocked vault");
            if (_vm.BackupSources.Sources.Count == 0
                && (string.IsNullOrWhiteSpace(_vm.BackupSource) || !Directory.Exists(_vm.BackupSource)))
                throw new InvalidOperationException("add a backup source (Backup tab) before Sync");
            UiNote("Backup Sync starting…");
            await _vm.SyncAsync();
            UiNote(_vm.Status);
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex, backupHint: true); }
    }

    private async void OnBrowseBackupSource(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            var folder = await picker.PickSingleFolderAsync();
            if (folder is not null)
            {
                BackupSourceBox.Text = folder.Path;
                _vm.BackupSource = folder.Path;
            }
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnAddBackupSource(object sender, RoutedEventArgs e)
    {
        try
        {
            PushToVm();
            if (string.IsNullOrWhiteSpace(_vm.BackupSource))
                throw new InvalidOperationException("source path required");
            _vm.AddBackupSource(_vm.BackupSource, string.IsNullOrWhiteSpace(_vm.VaultFolder) ? null : _vm.VaultFolder);
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnClearBackupSources(object sender, RoutedEventArgs e)
    {
        try
        {
            foreach (var id in _vm.BackupSources.Sources.Select(s => s.Id).ToList())
                _vm.RemoveBackupSource(id);
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnConnectExplorer(object sender, RoutedEventArgs e)
    {
        try
        {
            if (Application.Current is not App app)
                throw new InvalidOperationException("Desktop App host not ready");
            if (!_vm.IsUnlocked)
                throw new InvalidOperationException("unlock vault first — Connect Explorer needs an unlocked vault");
            UiNote("Connecting CfAPI Explorer viewer…");
            await app.ConnectExplorerManualAsync();
            UiNote(_vm.IsExplorerViewerConnected
                ? "Explorer viewer connected"
                : "Explorer connect finished (see log)");
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnDisconnectExplorer(object sender, RoutedEventArgs e)
    {
        try
        {
            if (Application.Current is not App app)
                throw new InvalidOperationException("Desktop App host not ready");
            app.DisconnectExplorerManual();
            UiNote("Explorer viewer disconnected");
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnExplorerBadgeClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (Application.Current is not App app)
                throw new InvalidOperationException("Desktop App host not ready");
            if (!_vm.IsExplorerViewerConnected)
            {
                if (!_vm.IsUnlocked)
                    throw new InvalidOperationException("unlock vault first — Connect Explorer needs an unlocked vault");
                UiNote("Connecting CfAPI Explorer viewer…");
                await app.ConnectExplorerManualAsync();
            }
            else
            {
                app.OpenExplorerSyncRoot();
                UiNote("Opened sync root in Explorer");
            }
            RefreshStatusStrip();
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnOpenExplorerPath(object sender, RoutedEventArgs e)
    {
        try
        {
            if (Application.Current is not App app)
                throw new InvalidOperationException("Desktop App host not ready");
            if (!_vm.IsExplorerViewerConnected)
                throw new InvalidOperationException("Explorer viewer not connected — unlock + Connect Explorer first");
            app.OpenExplorerSyncRoot();
            UiNote("Opened sync root in Explorer");
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnProxyModeClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (ProxyOffRadio.IsChecked == true)
                ProxyModeBox.Text = "direct";
            else if (ProxyCustomRadio.IsChecked == true)
                ProxyModeBox.Text = "custom";
            else
                ProxyModeBox.Text = "system";
            ApplyProxyModeUi();
            if (!_syncingUi)
            {
                PushToVm();
                _vm.SaveSettings();
                UiNote("Proxy mode: " + ProxyModeBox.Text);
            }
        }
        catch (Exception ex) { VmLog(ex); }
    }

    private void ApplyStorageModeUi()
    {
        var local = string.Equals(_vm.Settings.StorageMode, "local", StringComparison.OrdinalIgnoreCase);
        SetEnabled(LocalPathLabel, LocalVaultPathBox, local);
        SetEnabled(EndpointLabel, EndpointBox, !local);
        SetEnabled(RegionBucketLabel, RegionBox, !local);
        BucketBox.IsEnabled = !local;
        SetEnabled(PrefixAccessLabel, PrefixBox, !local);
        AccessKeyBox.IsEnabled = !local;
        PathStyleCheck.IsEnabled = !local;
        // Probe is S3-oriented; leave enabled so local users can still click and get a clear error.
    }

    private void ApplyProxyModeUi()
    {
        var mode = (ProxyModeBox.Text ?? _vm.Preferences.ProxyMode ?? "system").Trim().ToLowerInvariant();
        _syncingUi = true;
        try
        {
            ProxyOffRadio.IsChecked = mode == "direct";
            ProxySystemRadio.IsChecked = mode is not ("direct" or "custom");
            ProxyCustomRadio.IsChecked = mode == "custom";
            ProxyModeBox.Text = mode is "direct" or "custom" ? mode : "system";
            ProxyCustomPanel.Visibility = mode == "custom" ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { _syncingUi = false; }
    }

    private static void SetEnabled(UIElement label, Control field, bool enabled)
    {
        field.IsEnabled = enabled;
        if (label is FrameworkElement fe)
            fe.Opacity = enabled ? 1.0 : 0.45;
    }

    private void UiNote(string message)
    {
        var clean = message.Replace('\n', ' ');
        _vm.LogLine(clean);
        StatusBarText.Text = clean;
        BackupRemoteHintText.Text = "";
        RemoteHintText.Text = "";
        RefreshStatusStrip();
        // Keep the note visible in the status strip even if Status is unchanged.
        StatusBarText.Text = clean;
    }

    private void VmLog(Exception ex, bool backupHint = false)
    {
        System.Diagnostics.Debug.WriteLine(ex);
        var msg = ex.Message.Replace('\n', ' ');
        _vm.LogLine(msg);
        try { RefreshStatusStrip(); } catch { /* ignore */ }
        StatusBarText.Text = msg;
        if (backupHint)
            BackupRemoteHintText.Text = msg;
        else
            RemoteHintText.Text = msg;
    }

}
