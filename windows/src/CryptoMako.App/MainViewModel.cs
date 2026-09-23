using System.ComponentModel;
using System.Runtime.CompilerServices;
using CryptoMako.S3;
using CryptoMako.Vault;

namespace CryptoMako.App;

/// <summary>Shared host ViewModel: Vault / Backup / Settings parity with macOS tabs.</summary>
public sealed class MainViewModel : INotifyPropertyChanged, IAsyncDisposable
{
    public enum Tab { Vault, Backup, Settings }

    private readonly ISecretStore _secrets;
    private VaultSession? _session;
    private string _status = "locked";
    private string _log = "";
    private Tab _selectedTab = Tab.Vault;
    private string _password = "";
    private string _backupSource = "";
    private string _vaultFolder = Environment.MachineName;
    private bool _busy;
    private S3ProbeResult? _probe;
    private CancellationTokenSource? _monitorCts;
    private bool _userWantsUnlocked;
    private bool? _lastReachable;

    public MainViewModel(ISecretStore? secrets = null)
    {
        _secrets = secrets ?? CompositeSecretStore.Default;
        Settings = File.Exists(AppPaths.SettingsPath)
            ? VaultSettings.LoadFromFile(AppPaths.SettingsPath)
            : new VaultSettings();
        Preferences = File.Exists(AppPaths.PreferencesPath)
            ? AppPreferences.Deserialize(File.ReadAllText(AppPaths.PreferencesPath))
            : new AppPreferences();
        // Do not preload passphrase into the bindable Password field (crash-dump / UI lifetime).
        // UnlockAsync / auto-reconnect read CRYPTOMAKO_PASSWORD from the secret store when empty.
    }

    public VaultSettings Settings { get; private set; }
    public AppPreferences Preferences { get; private set; }

    public Tab SelectedTab
    {
        get => _selectedTab;
        set { if (_selectedTab != value) { _selectedTab = value; OnPropertyChanged(); } }
    }

    public string Status
    {
        get => _status;
        private set { if (_status != value) { _status = value; OnPropertyChanged(); OnPropertyChanged(nameof(StatusTrayLabel)); } }
    }

    public string Log
    {
        get => _log;
        private set { if (_log != value) { _log = value; OnPropertyChanged(); } }
    }

    public string Password
    {
        get => _password;
        set { if (_password != value) { _password = value; OnPropertyChanged(); } }
    }

    public string BackupSource
    {
        get => _backupSource;
        set { if (_backupSource != value) { _backupSource = value; OnPropertyChanged(); } }
    }

    public string VaultFolder
    {
        get => _vaultFolder;
        set { if (_vaultFolder != value) { _vaultFolder = value; OnPropertyChanged(); } }
    }

    public bool Busy
    {
        get => _busy;
        private set { if (_busy != value) { _busy = value; OnPropertyChanged(); OnPropertyChanged(nameof(StatusTrayLabel)); } }
    }

    public bool IsUnlocked => _session is not null;

    public string StatusTrayLabel =>
        Busy ? "busy…" : (IsUnlocked ? "unlocked" : Status);

    public string ProbeTrayLabel
    {
        get
        {
            if (LastProbe is null) return "not probed";
            static char L(ProbeLamp lamp) => lamp switch
            {
                ProbeLamp.Ok => '●',
                ProbeLamp.Fail => '✖',
                ProbeLamp.Skip => '–',
                _ => '○',
            };
            return $"dns{L(LastProbe.Dns)} tcp{L(LastProbe.Tcp)} https{L(LastProbe.Https)} list{L(LastProbe.List)}";
        }
    }

    public S3ProbeResult? LastProbe
    {
        get => _probe;
        private set { _probe = value; OnPropertyChanged(); OnPropertyChanged(nameof(ProbeTrayLabel)); }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public void SaveSettings()
    {
        Settings.NormalizeForSave();
        Settings.SaveToFile(AppPaths.SettingsPath);
        Preferences.ClampSyncWorkers();
        Directory.CreateDirectory(Path.GetDirectoryName(AppPaths.PreferencesPath)!);
        File.WriteAllText(AppPaths.PreferencesPath, Preferences.Serialize());
        AppendLog($"saved settings → {AppPaths.SettingsPath}");
    }

    public void SavePasswordToStore()
    {
        if (string.IsNullOrEmpty(Password))
            throw new InvalidOperationException("password empty");
        _secrets.SetSecret(SecretAccounts.Password, Password);
        Password = ""; // drop plaintext from UI binding after persist
        AppendLog($"saved {SecretAccounts.Password} to {(WindowsCredentialStore.IsSupported ? "Credential Manager" : "process env")}");
    }

    public async Task UnlockAsync(CancellationToken ct = default)
    {
        Busy = true;
        try
        {
            await LockAsync(clearWantUnlocked: false);
            var password = string.IsNullOrEmpty(Password)
                ? _secrets.GetSecret(SecretAccounts.Password)
                : Password;
            if (string.IsNullOrEmpty(password))
                throw new InvalidOperationException("vault password required");

            if (Settings.IsLocal)
            {
                if (string.IsNullOrWhiteSpace(Settings.LocalVaultPath))
                    throw new InvalidOperationException("localVaultPath required");
                _session = VaultSession.UnlockLocal(Settings.LocalVaultPath, password);
            }
            else
            {
                var secretKey = _secrets.GetSecret(SecretAccounts.SecretKey)
                    ?? throw new InvalidOperationException("CRYPTOMAKO_SECRET_KEY required");
                var proxyPass = _secrets.GetSecret(SecretAccounts.ProxyPassword);
                var s3 = S3Settings.From(
                    Settings.Endpoint, Settings.Region, Settings.Bucket,
                    Settings.AccessKey, secretKey, Settings.PathStyle);
                var http = S3ObjectStore.CreateHttpClient(Preferences, proxyPass);
                var store = new S3ObjectStore(s3, http, ownsHttpClient: true);
                _session = await VaultSession.UnlockAsync(store, Settings.NormalizedPrefix, password, ct: ct);
            }

            _userWantsUnlocked = true;
            Password = ""; // passphrase only needed for unlock; store keeps it if saved
            Status = $"unlocked format={_session.Metadata.Format} {_session.RootPath}";
            OnPropertyChanged(nameof(IsUnlocked));
            OnPropertyChanged(nameof(StatusTrayLabel));
            AppendLog(Status);
        }
        catch (Exception ex)
        {
            Status = "locked";
            AppendLog("unlock failed: " + ex.Message.Replace('\n', ' '));
            throw;
        }
        finally
        {
            Busy = false;
        }
    }

    public Task LockAsync(bool clearWantUnlocked = true)
    {
        _session?.Dispose();
        _session = null;
        Password = ""; // drop UI passphrase copy (CredMan wipe is deferred; in-process only)
        if (clearWantUnlocked)
            _userWantsUnlocked = false;
        Status = "locked";
        OnPropertyChanged(nameof(IsUnlocked));
        OnPropertyChanged(nameof(StatusTrayLabel));
        return Task.CompletedTask;
    }

    /// <summary>
    /// Periodic S3 probe (≈20s). When <see cref="VaultSettings.AutoReconnect"/> is on and the
    /// user previously unlocked (or auto-reconnect was enabled at launch), recover after outages.
    /// </summary>
    public void StartConnectivityMonitor()
    {
        StopConnectivityMonitor();
        var cts = new CancellationTokenSource();
        _monitorCts = cts;
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    await ProbeEndpointOnceAsync(cts.Token).ConfigureAwait(false);
                    await Task.Delay(TimeSpan.FromSeconds(20), cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    AppendLog("connectivity monitor: " + ex.Message.Replace('\n', ' '));
                    try { await Task.Delay(TimeSpan.FromSeconds(20), cts.Token).ConfigureAwait(false); }
                    catch (OperationCanceledException) { break; }
                }
            }
        }, cts.Token);
    }

    public void StopConnectivityMonitor()
    {
        try { _monitorCts?.Cancel(); } catch { /* ignore */ }
        _monitorCts?.Dispose();
        _monitorCts = null;
    }

    /// <summary>Call when the auto-reconnect checkbox is toggled (persists via SaveSettings).</summary>
    public async Task OnAutoReconnectChangedAsync(CancellationToken ct = default)
    {
        SaveSettings();
        if (Settings.AutoReconnect)
        {
            _userWantsUnlocked = true;
            await AttemptAutoUnlockAsync("preference", ct);
        }
        StartConnectivityMonitor();
    }

    /// <summary>Launch hook: start monitor; if autoReconnect, try unlock once.</summary>
    public async Task InitializeConnectivityAsync(CancellationToken ct = default)
    {
        StartConnectivityMonitor();
        if (Settings.AutoReconnect)
        {
            _userWantsUnlocked = true;
            await AttemptAutoUnlockAsync("launch", ct);
        }
    }

    private async Task ProbeEndpointOnceAsync(CancellationToken ct)
    {
        if (Settings.IsLocal)
        {
            _lastReachable = null;
            return;
        }

        var secretKey = _secrets.GetSecret(SecretAccounts.SecretKey);
        var proxyPass = _secrets.GetSecret(SecretAccounts.ProxyPassword);
        S3ProbeResult result;
        try
        {
            result = await S3Probe.ProbeAsync(Settings, secretKey, Preferences, proxyPass, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            result = new S3ProbeResult
            {
                Dns = ProbeLamp.Fail,
                Tcp = ProbeLamp.Fail,
                Https = ProbeLamp.Fail,
                List = ProbeLamp.Fail,
                Detail = ex.Message,
            };
        }

        // Do not assign LastProbe here — monitor runs off the UI thread; ProbeAsync owns lamps.
        // Reachable = TCP ok and HTTPS not failed (list may still fail without credentials).
        var ok = result.Tcp == ProbeLamp.Ok
                 && result.Https is not ProbeLamp.Fail
                 && result.Dns is not ProbeLamp.Fail;

        var previous = _lastReachable;
        _lastReachable = ok;

        if (ok)
        {
            if (previous == false)
            {
                AppendLog("S3 endpoint reachable again");
                await AttemptAutoUnlockAsync("reconnect", ct).ConfigureAwait(false);
            }
        }
        else if (previous != false)
        {
            AppendLog("No connectivity to S3 endpoint — check VPN or internet");
        }
    }

    private async Task AttemptAutoUnlockAsync(string reason, CancellationToken ct)
    {
        if (!Settings.AutoReconnect || !_userWantsUnlocked || IsUnlocked || Busy)
            return;
        if (!Settings.IsLocal && _lastReachable == false)
            return;
        AppendLog(reason == "reconnect" ? "Reconnecting to vault…" : "Automatic unlock…");
        try
        {
            await UnlockAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            // UnlockAsync already logged.
        }
    }

    public async Task ProbeAsync(CancellationToken ct = default)
    {
        Busy = true;
        try
        {
            var secretKey = _secrets.GetSecret(SecretAccounts.SecretKey);
            var proxyPass = _secrets.GetSecret(SecretAccounts.ProxyPassword);
            LastProbe = await S3Probe.ProbeAsync(Settings, secretKey, Preferences, proxyPass, ct);
            AppendLog($"probe dns={LastProbe.Dns} tcp={LastProbe.Tcp} https={LastProbe.Https} list={LastProbe.List} {LastProbe.Detail}");
        }
        finally
        {
            Busy = false;
        }
    }

    public async Task SyncAsync(CancellationToken ct = default)
    {
        if (_session is null)
            throw new InvalidOperationException("unlock vault first");
        if (string.IsNullOrWhiteSpace(BackupSource) || !Directory.Exists(BackupSource))
            throw new InvalidOperationException("--source directory required");
        if (string.IsNullOrWhiteSpace(VaultFolder))
            throw new InvalidOperationException("vault folder name required");

        Busy = true;
        try
        {
            var engine = new BackupSyncEngine();
            var progress = new Progress<string>(p => AppendLog(p));
            var result = await engine.SyncAsync(
                _session,
                BackupSource,
                VaultFolder.Trim(),
                Preferences,
                syncStatePath: AppPaths.SyncStatePath,
                progress: progress,
                ct: ct);
            AppendLog($"sync done uploaded={result.FilesUploaded} skipped={result.FilesSkipped} bytes={result.BytesUploaded}");
            Status = $"synced {result.FilesUploaded} files";
        }
        finally
        {
            Busy = false;
        }
    }

    public void ReloadSettingsFromDisk()
    {
        if (File.Exists(AppPaths.SettingsPath))
            Settings = VaultSettings.LoadFromFile(AppPaths.SettingsPath);
        if (File.Exists(AppPaths.PreferencesPath))
            Preferences = AppPreferences.Deserialize(File.ReadAllText(AppPaths.PreferencesPath));
        OnPropertyChanged(nameof(Settings));
        OnPropertyChanged(nameof(Preferences));
        AppendLog("reloaded settings from disk");
    }

    private void AppendLog(string line)
    {
        var stamp = DateTime.Now.ToString("HH:mm:ss");
        Log = string.IsNullOrEmpty(Log) ? $"[{stamp}] {line}" : Log + "\n" + $"[{stamp}] {line}";
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public async ValueTask DisposeAsync()
    {
        StopConnectivityMonitor();
        await LockAsync();
    }
}

