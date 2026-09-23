using System;
using Avalonia.Controls;
using Avalonia.Interactivity;
using CryptoMako.App;

namespace CryptoMako.Desktop;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Closing += OnClosing;
    }

    private void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        // Hide to tray instead of quitting (Quit lives on the tray menu).
        e.Cancel = true;
        Hide();
    }

    private MainViewModel Vm => (MainViewModel)DataContext!;

    private void OnModeLocal(object? sender, RoutedEventArgs e)
    {
        Vm.Settings.StorageMode = "local";
        Vm.SaveSettings();
    }

    private void OnModeS3(object? sender, RoutedEventArgs e)
    {
        Vm.Settings.StorageMode = "s3";
        Vm.SaveSettings();
    }

    private void OnSaveSettings(object? sender, RoutedEventArgs e)
    {
        try { Vm.SaveSettings(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnAutoReconnectClick(object? sender, RoutedEventArgs e)
    {
        try { await Vm.OnAutoReconnectChangedAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private void OnSavePassword(object? sender, RoutedEventArgs e)
    {
        try { Vm.SavePasswordToStore(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnUnlock(object? sender, RoutedEventArgs e)
    {
        try { await Vm.UnlockAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnLock(object? sender, RoutedEventArgs e)
    {
        try { await Vm.LockAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnProbe(object? sender, RoutedEventArgs e)
    {
        try { await Vm.ProbeAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private async void OnSync(object? sender, RoutedEventArgs e)
    {
        try { await Vm.SyncAsync(); }
        catch (Exception ex) { VmLog(ex); }
    }

    private void VmLog(Exception ex)
    {
        // MainViewModel already logs most failures; ensure UI shows something.
        System.Diagnostics.Debug.WriteLine(ex);
    }
}
