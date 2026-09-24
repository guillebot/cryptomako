using System.ComponentModel;
using System.Globalization;
using System.Threading;
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
    private CancellationTokenSource? _backupSyncCts;
    private bool _userWantsUnlocked;
    private bool? _lastReachable;
    private IExplorerViewer? _explorerViewer;
    private string? _vaultMetadataFingerprint;
    private bool _remoteChanged;
    private string _backupSourcesSummary = "(none)";
    private double _backupProgressPercent;
    private int _backupFilesDone;
    private int _backupFilesTotal;
    private long _backupBytesDone;
    private long _backupBytesTotal;
    private double _backupBytesPerSecond;
    private string _backupCurrentPath = "";
    private string _backupPhase = "";
    private string _backupProgressLabel = "";
    private string _backupSpeedLabel = "";
    private string _backupEtaLabel = "";

    public MainViewModel(ISecretStore? secrets = null)
    {
        _secrets = secrets ?? CompositeSecretStore.Default;
        Settings = File.Exists(AppPaths.SettingsPath)
            ? VaultSettings.LoadFromFile(AppPaths.SettingsPath)
            : new VaultSettings();
        Preferences = File.Exists(AppPaths.PreferencesPath)
            ? AppPreferences.Deserialize(File.ReadAllText(AppPaths.PreferencesPath))
            : new AppPreferences();
        BackupSources = File.Exists(AppPaths.BackupSourcesPath)
            ? BackupSourcesStore.LoadFromFile(AppPaths.BackupSourcesPath)
            : new BackupSourcesStore();
        RefreshBackupSourcesSummary();
        // Do not preload passphrase into the bindable Password field (crash-dump / UI lifetime).
        // UnlockAsync / auto-reconnect read CRYPTOMAKO_PASSWORD from the secret store when empty.
    }

    public VaultSettings Settings { get; private set; }
    public AppPreferences Preferences { get; private set; }
    /// <summary>Windows-local list (backup-sources.json); not settings.json.</summary>
    public BackupSourcesStore BackupSources { get; private set; }

    public string BackupSourcesSummary
    {
        get => _backupSourcesSummary;
        private set { if (_backupSourcesSummary != value) { _backupSourcesSummary = value; OnPropertyChanged(); } }
    }

    /// <summary>0–100 Backup Sync progress (bytes when known, else files). Cleared when idle.</summary>
    public double BackupProgressPercent
    {
        get => _backupProgressPercent;
        private set { if (Math.Abs(_backupProgressPercent - value) > 0.01) { _backupProgressPercent = value; OnPropertyChanged(); } }
    }

    public int BackupFilesDone
    {
        get => _backupFilesDone;
        private set { if (_backupFilesDone != value) { _backupFilesDone = value; OnPropertyChanged(); } }
    }

    public int BackupFilesTotal
    {
        get => _backupFilesTotal;
        private set { if (_backupFilesTotal != value) { _backupFilesTotal = value; OnPropertyChanged(); } }
    }

    public long BackupBytesDone
    {
        get => _backupBytesDone;
        private set { if (_backupBytesDone != value) { _backupBytesDone = value; OnPropertyChanged(); } }
    }

    public long BackupBytesTotal
    {
        get => _backupBytesTotal;
        private set { if (_backupBytesTotal != value) { _backupBytesTotal = value; OnPropertyChanged(); } }
    }

    public double BackupBytesPerSecond
    {
        get => _backupBytesPerSecond;
        private set { if (Math.Abs(_backupBytesPerSecond - value) > 0.1) { _backupBytesPerSecond = value; OnPropertyChanged(); OnPropertyChanged(nameof(BackupSpeedLabel)); } }
    }

    public string BackupCurrentPath
    {
        get => _backupCurrentPath;
        private set { if (_backupCurrentPath != value) { _backupCurrentPath = value; OnPropertyChanged(); } }
    }

    public string BackupPhase
    {
        get => _backupPhase;
        private set { if (_backupPhase != value) { _backupPhase = value; OnPropertyChanged(); } }
    }

    public string BackupProgressLabel
    {
        get => _backupProgressLabel;
        private set { if (_backupProgressLabel != value) { _backupProgressLabel = value; OnPropertyChanged(); } }
    }

    public string BackupSpeedLabel
    {
        get => _backupSpeedLabel;
        private set { if (_backupSpeedLabel != value) { _backupSpeedLabel = value; OnPropertyChanged(); } }
    }

    public string BackupEtaLabel
    {
        get => _backupEtaLabel;
        private set { if (_backupEtaLabel != value) { _backupEtaLabel = value; OnPropertyChanged(); } }
    }

    public bool IsBackupProgressVisible => IsBackupSyncRunning || BackupProgressPercent > 0 || !string.IsNullOrEmpty(BackupPhase);

    /// <summary>True when vault.cryptomator fingerprint changed since unlock (no merge).</summary>
    public bool RemoteChanged
    {
        get => _remoteChanged;
        private set
        {
            if (_remoteChanged != value)
            {
                _remoteChanged = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(RemoteChangeHint));
            }
        }
    }

    public string RemoteChangeHint =>
        RemoteChanged ? "remote changed — remount/refresh" : "";

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

    /// <summary>Live vault session while unlocked; null when locked.</summary>
    public VaultSession? Session => _session;

    public string StatusTrayLabel =>
        Busy ? "busy…" : (IsUnlocked ? "unlocked" : Status);

    /// <summary>Optional soft CfAPI viewer. Bound by Desktop/CLI after a successful sync-root Connect.</summary>
    public IExplorerViewer? ExplorerViewer
    {
        get => _explorerViewer;
        set
        {
            if (!ReferenceEquals(_explorerViewer, value))
            {
                _explorerViewer = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsExplorerViewerConnected));
            }
        }
    }

    /// <summary>True when a bound soft CfAPI viewer reports connected.</summary>
    public bool IsExplorerViewerConnected => _explorerViewer?.IsConnected == true;

    /// <summary>Bind (or clear) the live soft CfAPI provider so Lock can Disconnect it.</summary>
    public void BindExplorerViewer(IExplorerViewer? viewer)
    {
        ExplorerViewer = viewer;
        if (viewer is null)
            AppendLog("CfAPI viewer cleared");
        else if (viewer.IsConnected)
            AppendLog("CfAPI viewer bound (connected)");
        else
            AppendLog("CfAPI viewer bound");
    }

    /// <summary>True while a Backup Sync run is cancellable via Lock.</summary>
    public bool IsBackupSyncRunning =>
        _backupSyncCts is not null && !_backupSyncCts.IsCancellationRequested;

    public string ProbeTrayLabel
    {
        get
        {
            static char L(ProbeLamp lamp) => lamp switch
            {
                ProbeLamp.Ok => 'o',
                ProbeLamp.Fail => 'x',
                ProbeLamp.Skip => '-',
                _ => '?',
            };
            var probe = LastProbe is null
                ? "dns? tcp? https? s3list?"
                : $"dns{L(LastProbe.Dns)} tcp{L(LastProbe.Tcp)} https{L(LastProbe.Https)} s3list{L(LastProbe.List)}";
            var unlocked = IsUnlocked ? "unlocked=o" : "unlocked=?";
            return $"{probe} {unlocked}";
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
            OnPropertyChanged(nameof(ProbeTrayLabel));
            OnPropertyChanged(nameof(StatusTrayLabel));
            AppendLog(Status);
            await CaptureVaultMetadataFingerprintAsync(ct);
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
        // Platforms Lock High: cancel Backup Sync, then disconnect CfAPI viewer.
        // CredMan / secret-store wipe is deferred - do not call DeleteSecret here.
        CancelBackupSync();
        DisconnectExplorerViewer();

        _session?.Dispose();
        _session = null;
        Password = ""; // drop UI passphrase copy (CredMan wipe is deferred; in-process only)
        _vaultMetadataFingerprint = null;
        RemoteChanged = false;
        if (clearWantUnlocked)
            _userWantsUnlocked = false;
        Status = "locked";
        OnPropertyChanged(nameof(IsUnlocked));
            OnPropertyChanged(nameof(ProbeTrayLabel));
        OnPropertyChanged(nameof(StatusTrayLabel));
        OnPropertyChanged(nameof(IsBackupSyncRunning));
        return Task.CompletedTask;
    }

    /// <summary>Cancel an in-flight Backup Sync (no-op if idle). Does not wipe CredMan.</summary>
    public void CancelBackupSync()
    {
        try { _backupSyncCts?.Cancel(); }
        catch { /* ignore */ }
        OnPropertyChanged(nameof(IsBackupSyncRunning));
        AppendLog("Backup Sync cancel requested");
    }

    /// <summary>Disconnect soft CfAPI viewer if connected, then clear the binding. Does not unregister the sync root.</summary>
    public void DisconnectExplorerViewer()
    {
        var viewer = _explorerViewer;
        if (viewer is null) return;
        try
        {
            if (viewer.IsConnected)
            {
                viewer.Disconnect();
                AppendLog("CfAPI viewer disconnected");
            }
        }
        catch (Exception ex)
        {
            AppendLog("CfAPI disconnect: " + ex.Message.Replace('\n', ' '));
        }
        finally
        {
            // Clear so the next Connect re-binds a live provider (Lock High complete).
            if (ReferenceEquals(_explorerViewer, viewer))
                ExplorerViewer = null;
        }
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

    private int _probeInFlight;

    private async Task ProbeEndpointOnceAsync(CancellationToken ct)
    {
        if (Settings.IsLocal)
        {
            _lastReachable = null;
            return;
        }

        // Debounce overlapping auto-probes (manual ProbeAsync sets Busy separately).
        if (Interlocked.CompareExchange(ref _probeInFlight, 1, 0) != 0)
            return;
        try
        {
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

            // Auto probe updates the same lamps as the manual Probe S3 button (macOS parity).
            LastProbe = result;

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

            if (IsUnlocked)
                await CheckRemoteChangeAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            Interlocked.Exchange(ref _probeInFlight, 0);
        }
    }

    private async Task AttemptAutoUnlockAsync(string reason, CancellationToken ct)
    {
        // Match macOS: gate on shared VaultSettings.autoReconnect (no new keys).
        if (!Settings.AutoReconnect || !_userWantsUnlocked || IsUnlocked || Busy)
            return;
        if (!Settings.IsLocal && _lastReachable == false)
            return;

        // Soft preflight — stay Locked with a clear status; never wipe CredMan.
        var hasPassword = !string.IsNullOrEmpty(Password)
            || !string.IsNullOrEmpty(_secrets.GetSecret(SecretAccounts.Password));
        if (!hasPassword)
        {
            Status = "locked";
            AppendLog("Automatic unlock skipped — no passphrase in Credential Manager");
            return;
        }
        if (Settings.IsLocal)
        {
            if (string.IsNullOrWhiteSpace(Settings.LocalVaultPath))
            {
                Status = "locked";
                AppendLog("Automatic unlock skipped — localVaultPath not set");
                return;
            }
        }
        else if (string.IsNullOrWhiteSpace(Settings.Endpoint)
                 || string.IsNullOrWhiteSpace(Settings.Bucket)
                 || string.IsNullOrEmpty(_secrets.GetSecret(SecretAccounts.SecretKey)))
        {
            Status = "locked";
            AppendLog("Automatic unlock skipped — S3 settings or CRYPTOMAKO_SECRET_KEY incomplete");
            return;
        }

        AppendLog(reason == "reconnect" ? "Reconnecting to vault…" : "Automatic unlock…");
        try
        {
            await UnlockAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            // UnlockAsync already set Status=locked and logged; soft-fail stays Locked.
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
            if (IsUnlocked)
                await CheckRemoteChangeAsync(ct);
        }
        finally
        {
            Busy = false;
        }
    }

    /// <summary>
    /// Sync all persisted backup sources. Soft-warn was at add time; Sync hard-fails on nested overlap.
    /// If the list is empty, falls back to the single BackupSource / VaultFolder fields (CLI/desktop one-shot).
    /// </summary>
    public async Task SyncAsync(CancellationToken ct = default)
    {
        if (_session is null)
            throw new InvalidOperationException("unlock vault first");

        var sources = BackupSources.Sources.ToList();
        if (sources.Count == 0)
        {
            if (string.IsNullOrWhiteSpace(BackupSource) || !Directory.Exists(BackupSource))
                throw new InvalidOperationException("add a backup source (or set Source path)");
            if (string.IsNullOrWhiteSpace(VaultFolder))
                throw new InvalidOperationException("vault folder name required");
            sources.Add(CreateBackupSourceEntry(BackupSource, VaultFolder.Trim()));
        }

        BackupPathOverlap.ThrowIfOverlapping(sources);

        Busy = true;
        var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var prev = Interlocked.Exchange(ref _backupSyncCts, linked);
        try { prev?.Cancel(); } catch { /* ignore */ }
        prev?.Dispose();
        ResetBackupProgress("scanning");
        OnPropertyChanged(nameof(IsBackupSyncRunning));
        OnPropertyChanged(nameof(IsBackupProgressVisible));
        try
        {
            var engine = new BackupSyncEngine();
            var progress = new Progress<string>(p => AppendLog(p));
            var syncProgress = new Progress<BackupSyncProgressUpdate>(ApplyBackupProgress);
            var uploaded = 0;
            var skipped = 0;
            var scanned = 0;
            long bytes = 0;
            long bytesScanned = 0;
            foreach (var src in sources)
            {
                linked.Token.ThrowIfCancellationRequested();
                AppendLog($"sync source {src.VaultFolderName} ? {src.Path}");
                BackupPhase = "uploading";
                BackupCurrentPath = src.Path;
                var result = await engine.SyncAsync(
                    _session,
                    src.Path,
                    src.VaultFolderName,
                    Preferences,
                    syncStatePath: AppPaths.SyncStatePath,
                    progress: progress,
                    syncProgress: syncProgress,
                    ct: linked.Token);
                uploaded += result.FilesUploaded;
                skipped += result.FilesSkipped;
                scanned += result.FilesScanned;
                bytes += result.BytesUploaded;
                bytesScanned += result.BytesScanned;
            }
            AppendLog($"sync done uploaded={uploaded} skipped={skipped} scanned={scanned} bytes={bytes}");
            Status = uploaded > 0
                ? $"synced {uploaded} files"
                : (scanned > 0 ? $"up-to-date ({scanned} files)" : "sync: no files");
            BackupPhase = "done";
            BackupProgressPercent = 100;
            BackupFilesDone = uploaded + skipped;
            BackupFilesTotal = Math.Max(scanned, uploaded + skipped);
            BackupBytesDone = Math.Max(bytes, bytesScanned);
            BackupBytesTotal = Math.Max(bytesScanned, bytes);
            if (scanned == 0)
                BackupProgressLabel = "Finished - no files found under backup sources";
            else if (uploaded == 0)
                BackupProgressLabel = $"Finished - all {scanned} files up-to-date - {FormatBytes(bytesScanned)}";
            else if (skipped > 0)
                BackupProgressLabel = $"Finished - {uploaded} uploaded, {skipped} up-to-date ({scanned} files total) - {FormatBytes(Math.Max(bytes, bytesScanned))}";
            else
                BackupProgressLabel = $"Finished - {uploaded} files uploaded ({scanned} scanned) - {FormatBytes(bytes)}";
            BackupSpeedLabel = "";
            BackupEtaLabel = "";
            BackupCurrentPath = "";
        }
        catch (OperationCanceledException)
        {
            BackupPhase = "cancelled";
            BackupProgressLabel = "Cancelled";
            BackupSpeedLabel = "";
            BackupEtaLabel = "";
            throw;
        }
        catch
        {
            BackupPhase = "error";
            throw;
        }
        finally
        {
            if (ReferenceEquals(_backupSyncCts, linked))
                _backupSyncCts = null;
            linked.Dispose();
            OnPropertyChanged(nameof(IsBackupSyncRunning));
            OnPropertyChanged(nameof(IsBackupProgressVisible));
            Busy = false;
            BackupBytesPerSecond = 0;
            BackupSpeedLabel = "";
            BackupEtaLabel = "";
        }
    }

    /// <summary>Add a source path. Soft-warns (log) on nested overlap; still persists the add.</summary>
    public string? AddBackupSource(string path, string? vaultFolderName = null)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("path required", nameof(path));
        var warn = BackupPathOverlap.SoftWarnOnAdd(BackupSources.Sources, path);
        var src = CreateBackupSourceEntry(path, vaultFolderName);
        if (BackupSources.Sources.Any(s =>
                string.Equals(BackupPathOverlap.Resolve(s.Path), BackupPathOverlap.Resolve(src.Path),
                    OperatingSystem.IsWindows() || OperatingSystem.IsMacOS()
                        ? StringComparison.OrdinalIgnoreCase
                        : StringComparison.Ordinal)))
        {
            AppendLog($"backup source already listed: {src.Path}");
            return warn;
        }
        BackupSources.Sources.Add(src);
        PersistBackupSources();
        if (warn is not null)
            AppendLog(warn);
        else
            AppendLog($"added backup source {src.VaultFolderName} ← {src.Path}");
        return warn;
    }

    public void RemoveBackupSource(string id)
    {
        var n = BackupSources.Sources.RemoveAll(s => s.Id == id);
        if (n > 0)
        {
            PersistBackupSources();
            AppendLog($"removed backup source id={id}");
        }
    }

    public void PersistBackupSources()
    {
        BackupSources.SaveToFile(AppPaths.BackupSourcesPath);
        RefreshBackupSourcesSummary();
        OnPropertyChanged(nameof(BackupSources));
    }

    private void RefreshBackupSourcesSummary()
    {
        if (BackupSources.Sources.Count == 0)
            BackupSourcesSummary = "(none)";
        else
            BackupSourcesSummary = string.Join("\n",
                BackupSources.Sources.Select(s => $"• {s.VaultFolderName} ← {s.Path}"));
    }


    private static global::CryptoMako.Vault.BackupSource CreateBackupSourceEntry(string path, string? vaultFolderName = null) =>
        global::CryptoMako.Vault.BackupSource.Create(path, vaultFolderName);

    private async Task CaptureVaultMetadataFingerprintAsync(CancellationToken ct)
    {
        if (_session is null) return;
        try
        {
            _vaultMetadataFingerprint = await _session.GetVaultMetadataFingerprintAsync(ct);
            RemoteChanged = false;
            AppendLog("vault metadata fingerprint captured");
        }
        catch (Exception ex)
        {
            AppendLog("vault metadata fingerprint: " + ex.Message.Replace('\n', ' '));
        }
    }

    /// <summary>Read-only ETag/size check; surfaces remount/refresh hint. No merge.</summary>
    public async Task CheckRemoteChangeAsync(CancellationToken ct = default)
    {
        if (_session is null || _vaultMetadataFingerprint is null) return;
        try
        {
            var now = await _session.GetVaultMetadataFingerprintAsync(ct);
            if (!string.Equals(now, _vaultMetadataFingerprint, StringComparison.Ordinal))
            {
                if (!RemoteChanged)
                {
                    RemoteChanged = true;
                    AppendLog("remote changed — remount/refresh");
                    if (!Status.Contains("remote changed", StringComparison.OrdinalIgnoreCase))
                        Status = "remote changed — remount/refresh";
                }
            }
        }
        catch (Exception ex)
        {
            AppendLog("remote-change probe: " + ex.Message.Replace('\n', ' '));
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


    private void ResetBackupProgress(string phase)
    {
        BackupPhase = phase;
        BackupProgressPercent = 0;
        BackupFilesDone = 0;
        BackupFilesTotal = 0;
        BackupBytesDone = 0;
        BackupBytesTotal = 0;
        BackupBytesPerSecond = 0;
        BackupCurrentPath = "";
        BackupProgressLabel = phase == "scanning" ? "Counting local files..." : "";
        BackupSpeedLabel = "";
        BackupEtaLabel = "";
        OnPropertyChanged(nameof(IsBackupProgressVisible));
    }

    private void ApplyBackupProgress(BackupSyncProgressUpdate u)
    {
        BackupPhase = u.Phase;
        BackupFilesDone = u.FilesDone;
        BackupFilesTotal = u.FilesTotal;
        BackupBytesDone = u.BytesDone;
        BackupBytesTotal = u.BytesTotal;
        BackupBytesPerSecond = u.BytesPerSecond;
        BackupCurrentPath = u.CurrentPath ?? "";
        BackupProgressPercent = u.Percent;
        var totalFiles = Math.Max(u.FilesScanned, Math.Max(u.FilesTotal, u.FilesDone));
        if (totalFiles > 0 || u.BytesTotal > 0 || u.BytesScanned > 0)
        {
            var bytesTot = Math.Max(u.BytesScanned, u.BytesTotal);
            BackupProgressLabel = string.Format(
                CultureInfo.InvariantCulture,
                "{0:0}% - {1}/{2} files - {3}/{4}",
                u.Percent,
                u.FilesDone,
                totalFiles,
                FormatBytes(u.BytesDone),
                FormatBytes(bytesTot > 0 ? bytesTot : u.BytesTotal));
        }
        else if (u.FilesScanned > 0)
        {
            BackupProgressLabel = u.FilesSkipped >= u.FilesScanned
                ? $"All {u.FilesSkipped} files up-to-date - {FormatBytes(u.BytesScanned)}"
                : $"Scanned {u.FilesScanned} files...";
        }
        else if (u.Phase == "scanning")
            BackupProgressLabel = "Counting local files...";
        else
            BackupProgressLabel = string.IsNullOrWhiteSpace(u.CurrentPath) ? u.Phase : u.CurrentPath;
        BackupSpeedLabel = u.BytesPerSecond > 0 ? FormatRate(u.BytesPerSecond) : "";
        BackupEtaLabel = FormatEta(u.BytesDone, u.BytesTotal, u.BytesPerSecond);
        OnPropertyChanged(nameof(IsBackupProgressVisible));
    }

    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        double v = bytes;
        string[] units = ["KB", "MB", "GB", "TB"];
        var u = -1;
        do { v /= 1024; u++; } while (v >= 1024 && u < units.Length - 1);
        return string.Format(CultureInfo.InvariantCulture, "{0:0.##} {1}", v, units[u]);
    }

    public static string FormatRate(double bytesPerSecond)
    {
        if (bytesPerSecond <= 0) return "";
        return FormatBytes((long)bytesPerSecond) + "/s";
    }

    public static string FormatEta(long bytesDone, long bytesTotal, double bytesPerSecond)
    {
        if (bytesPerSecond <= 1 || bytesTotal <= bytesDone) return "";
        var remain = (bytesTotal - bytesDone) / bytesPerSecond;
        if (remain < 60) return string.Format(CultureInfo.InvariantCulture, "ETA {0:0}s", remain);
        if (remain < 3600) return string.Format(CultureInfo.InvariantCulture, "ETA {0:0.0}m", remain / 60);
        return string.Format(CultureInfo.InvariantCulture, "ETA {0:0.0}h", remain / 3600);
    }

    /// <summary>Host/UI log sink (Explorer connect, soft CfAPI notes).</summary>
    public void LogLine(string line) => AppendLog(line);

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

