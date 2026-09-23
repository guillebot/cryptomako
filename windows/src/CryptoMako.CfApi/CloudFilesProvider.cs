using CryptoMako.Vault;

namespace CryptoMako.CfApi;

/// <summary>
/// Scaffold for a Windows Cloud Files (CfAPI) sync root.
/// Real CfRegisterSyncRoot / CF_CALLBACK_REGISTRATION require Windows 10+ and
/// must run on a Windows box — this assembly compiles everywhere with stubs.
/// </summary>
public sealed class CloudFilesProvider
{
    public const string ProviderName = "CryptoMako";
    public const string SyncRootIdPrefix = "CryptoMako!";

    public string SyncRootPath { get; }
    public VaultSession? Session { get; private set; }

    public CloudFilesProvider(string syncRootPath)
    {
        SyncRootPath = Path.GetFullPath(syncRootPath);
    }

    public bool IsWindowsCloudFilesAvailable =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134);

    /// <summary>
    /// Registers a sync root. On non-Windows throws <see cref="PlatformNotSupportedException"/>.
    /// Fail-closed policy: placeholders may hydrate only after remote get; local writes
    /// must complete remote put (2xx) before acknowledging durable success.
    /// </summary>
    public void RegisterSyncRoot(string accountName)
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException(
                "CfAPI sync root registration requires Windows 10 1803+ (build on a Windows machine).");

        // Windows-only P/Invoke / CsWin32 surface lands here later.
        // Documented registration steps: windows/docs/cfapi.md
        Directory.CreateDirectory(SyncRootPath);
        _ = accountName;
        throw new NotImplementedException(
            "CfRegisterSyncRoot wrapper not yet linked — see docs/cfapi.md for the Windows checklist.");
    }

    public void UnregisterSyncRoot()
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI requires Windows.");
        throw new NotImplementedException("CfUnregisterSyncRoot wrapper not yet linked.");
    }

    public void AttachSession(VaultSession session) => Session = session;

    /// <summary>
    /// Policy helper: Explorer/CfAPI materialization is never the durability boundary.
    /// Backup Sync / remote put ACK is.
    /// </summary>
    public static bool IsDurableSuccess(bool remotePutHttp2xx) => remotePutHttp2xx;

    public CloudFilesStatus GetStatus() => new()
    {
        SyncRootPath = SyncRootPath,
        PlatformSupported = IsWindowsCloudFilesAvailable,
        SessionAttached = Session is not null,
        Registered = false,
    };
}

public sealed class CloudFilesStatus
{
    public required string SyncRootPath { get; init; }
    public bool PlatformSupported { get; init; }
    public bool SessionAttached { get; init; }
    public bool Registered { get; init; }
}

/// <summary>Placeholder identity for a cleartext vault path (maps to ciphertext object key).</summary>
public sealed class CloudFilesPlaceholder
{
    public required string CleartextRelativePath { get; init; }
    public required string CiphertextKey { get; init; }
    public bool IsDirectory { get; init; }
    public long? FileSize { get; init; }
}
