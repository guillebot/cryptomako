using System.Runtime.InteropServices;
using System.Text;
using CryptoMako.Vault;

namespace CryptoMako.CfApi;

/// <summary>
/// Windows Cloud Files (CfAPI) sync root provider.
/// Compiles on all platforms; live register/unregister requires Windows 10 1803+.
/// Fail-closed: Explorer materialization is never durability — remote put 2xx is.
/// </summary>
public sealed class CloudFilesProvider : IDisposable
{
    public const string ProviderName = "CryptoMako";
    public const string ProviderVersion = "0.1.0";
    public const string SyncRootIdPrefix = "CryptoMako!";
    public static readonly Guid ProviderId = new("C8A7E5D1-4B2F-4E9A-9C31-7F6D2A1B0E44");

    public string SyncRootPath { get; }
    public VaultSession? Session { get; private set; }

    private bool _registered;
    private long _connectionKey;
    private bool _connected;
    private string? _accountName;

    public CloudFilesProvider(string syncRootPath)
    {
        SyncRootPath = Path.GetFullPath(syncRootPath);
    }

    public bool IsWindowsCloudFilesAvailable =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134);

    /// <summary>
    /// Registers a sync root via CfRegisterSyncRoot.
    /// No admin elevation required for a user-writable folder (needs WRITE_DATA).
    /// </summary>
    public void RegisterSyncRoot(string accountName)
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException(
                "CfAPI sync root registration requires Windows 10 1803+.");

        if (string.IsNullOrWhiteSpace(accountName))
            throw new ArgumentException("account name required", nameof(accountName));

        Directory.CreateDirectory(SyncRootPath);
        _accountName = accountName.Trim();
        var identity = Encoding.Unicode.GetBytes(SyncRootIdPrefix + _accountName + "\0");

        var providerNamePtr = Marshal.StringToHGlobalUni(ProviderName);
        var providerVersionPtr = Marshal.StringToHGlobalUni(ProviderVersion);
        var identityPtr = Marshal.AllocHGlobal(identity.Length);
        try
        {
            Marshal.Copy(identity, 0, identityPtr, identity.Length);

            var registration = new CldApiNative.CF_SYNC_REGISTRATION
            {
                StructSize = (uint)Marshal.SizeOf<CldApiNative.CF_SYNC_REGISTRATION>(),
                ProviderName = providerNamePtr,
                ProviderVersion = providerVersionPtr,
                SyncRootIdentity = identityPtr,
                SyncRootIdentityLength = (uint)identity.Length,
                FileIdentity = IntPtr.Zero,
                FileIdentityLength = 0,
                ProviderId = ProviderId,
            };

            var policies = new CldApiNative.CF_SYNC_POLICIES
            {
                StructSize = (uint)Marshal.SizeOf<CldApiNative.CF_SYNC_POLICIES>(),
                Hydration = new CldApiNative.CF_HYDRATION_POLICY
                {
                    Primary = CldApiNative.CF_HYDRATION_POLICY_PARTIAL,
                    Modifier = CldApiNative.CF_HYDRATION_POLICY_MODIFIER_NONE,
                },
                Population = new CldApiNative.CF_POPULATION_POLICY
                {
                    Primary = CldApiNative.CF_POPULATION_POLICY_PARTIAL,
                    Modifier = CldApiNative.CF_POPULATION_POLICY_MODIFIER_NONE,
                },
                InSync = CldApiNative.CF_INSYNC_POLICY_NONE,
                HardLink = CldApiNative.CF_HARDLINK_POLICY_NONE,
                PlaceholderManagement = CldApiNative.CF_PLACEHOLDER_MANAGEMENT_POLICY_DEFAULT,
            };

            var hr = CldApiNative.CfRegisterSyncRoot(
                SyncRootPath,
                in registration,
                in policies,
                CldApiNative.CF_REGISTER_FLAG_UPDATE | CldApiNative.CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT);
            CldApiNative.ThrowOnFailed(hr, nameof(CldApiNative.CfRegisterSyncRoot));
            _registered = true;
        }
        finally
        {
            Marshal.FreeHGlobal(providerNamePtr);
            Marshal.FreeHGlobal(providerVersionPtr);
            Marshal.FreeHGlobal(identityPtr);
        }
    }

    public void UnregisterSyncRoot()
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI requires Windows.");

        Disconnect();
        var hr = CldApiNative.CfUnregisterSyncRoot(SyncRootPath);
        CldApiNative.ThrowOnFailed(hr, nameof(CldApiNative.CfUnregisterSyncRoot));
        _registered = false;
    }

    /// <summary>
    /// Connect callback channel. Currently blocked: CfConnectSyncRoot returns E_INVALIDARG
    /// until CsWin32-safe CF_CALLBACK delegates (FETCH_DATA / fail-closed writes) are wired.
    /// Register/Unregister are live and tested on Windows 11.
    /// </summary>
    public void Connect()
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI requires Windows.");
        if (!_registered)
            throw new InvalidOperationException("RegisterSyncRoot first.");
        if (_connected) return;

        throw new NotImplementedException(
            "CfConnectSyncRoot needs CsWin32/safe CF_CALLBACK marshalling " +
            "(observed HRESULT 0x80070057 with terminator-only / null tables on Win11 26100). " +
            "Register + Unregister work. See docs/cfapi.md.");
    }

    public void Disconnect()
    {
        if (!_connected) return;
        try { CldApiNative.CfDisconnectSyncRoot(_connectionKey); }
        catch { /* best-effort */ }
        _connected = false;
        _connectionKey = 0;
    }

    public void AttachSession(VaultSession session) => Session = session;

    public static bool IsDurableSuccess(bool remotePutHttp2xx) => remotePutHttp2xx;

    public static void AcknowledgeWriteOnlyIfRemoteOk(bool remotePutHttp2xx)
    {
        if (!IsDurableSuccess(remotePutHttp2xx))
            throw new InvalidOperationException(
                "CfAPI write not durable: remote put/delete did not return HTTP 2xx (fail-closed).");
    }

    public static string? TryGetPlatformInfo()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return null;
        try
        {
            var hr = CldApiNative.CfGetPlatformInfo(out var info);
            if (hr < 0) return $"CfGetPlatformInfo HRESULT=0x{hr:X8}";
            return $"build={info.BuildNumber} revision={info.RevisionNumber} integration={info.IntegrationNumber}";
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    public CloudFilesStatus GetStatus() => new()
    {
        SyncRootPath = SyncRootPath,
        PlatformSupported = IsWindowsCloudFilesAvailable,
        SessionAttached = Session is not null,
        Registered = _registered,
        Connected = _connected,
        AccountName = _accountName,
        PlatformInfo = TryGetPlatformInfo(),
    };

    public void Dispose()
    {
        Disconnect();
        GC.SuppressFinalize(this);
    }
}

public sealed class CloudFilesStatus
{
    public required string SyncRootPath { get; init; }
    public bool PlatformSupported { get; init; }
    public bool SessionAttached { get; init; }
    public bool Registered { get; init; }
    public bool Connected { get; init; }
    public string? AccountName { get; init; }
    public string? PlatformInfo { get; init; }
}

public sealed class CloudFilesPlaceholder
{
    public required string CleartextRelativePath { get; init; }
    public required string CiphertextKey { get; init; }
    public bool IsDirectory { get; init; }
    public long? FileSize { get; init; }
}
