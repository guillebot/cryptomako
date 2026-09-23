using System.Runtime.InteropServices;
using System.Text;
using CryptoMako.Vault;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using static Vanara.PInvoke.Kernel32;
using System.Security.Cryptography;

namespace CryptoMako.CfApi;

/// <summary>
/// Windows Cloud Files provider (Vanara-backed P/Invoke).
/// Register / Connect / placeholders / FETCH_DATA hydrate are live on Windows 10 1803+.
/// WinRT StorageProviderSyncRootManager on CFAPI_WINRT builds (Explorer cloud glyph).
/// Fail-closed: write/delete/rename notify never claims durable success without remote 2xx.
/// </summary>
public sealed class CloudFilesProvider : IDisposable
{
    public const string ProviderName = "CryptoMako";
    public const string ProviderVersion = "0.1.0";
    public const string SyncRootIdPrefix = "CryptoMako!";
    public static readonly Guid ProviderId = new("C8A7E5D1-4B2F-4E9A-9C31-7F6D2A1B0E44");

    // STATUS_CLOUD_FILE_ACCESS_DENIED — reject delete/rename until vault mutation is wired.
    private static readonly NTStatus StatusCloudFileAccessDenied = new(unchecked((int)0xC000CF0B));

    public string SyncRootPath { get; }
    public VaultSession? Session { get; private set; }

    private bool _registered;
    private bool _registeredViaWinRt;
    private bool _connected;
    private CF_CONNECTION_KEY _connectionKey;
    private string? _accountName;
    private string? _shellSyncRootId;
    private string? _shellDetail;
    private GCHandle _selfHandle;
    private CF_CALLBACK? _fetchData;
    private CF_CALLBACK? _cancelFetch;
    private CF_CALLBACK? _notifyClose;
    private CF_CALLBACK? _notifyDelete;
    private CF_CALLBACK? _notifyRename;
    private CF_CALLBACK_REGISTRATION[]? _callbackTable;
    private IntPtr _syncRootIdentityPtr;
    private int _syncRootIdentityLen;

    public CloudFilesProvider(string syncRootPath)
    {
        SyncRootPath = Path.GetFullPath(syncRootPath);
    }

    public bool IsWindowsCloudFilesAvailable =>
        OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134);

    public void RegisterSyncRoot(string accountName)
    {
        EnsureWindows();
        if (string.IsNullOrWhiteSpace(accountName))
            throw new ArgumentException("account name required", nameof(accountName));

        Directory.CreateDirectory(SyncRootPath);
        _accountName = accountName.Trim();

        // WinRT StorageProviderSyncRootManager.Register also registers with CfAPI.
        // Do not CfRegisterSyncRoot after a successful WinRT register (double-register → invalid).
        if (ShellSyncRoot.SupportsWinRt &&
            ShellSyncRoot.TryRegisterWinRtOnly(SyncRootPath, _accountName, out var winRtId, out var winRtDetail))
        {
            _shellSyncRootId = winRtId;
            _shellDetail = winRtDetail;
            _registered = true;
            _registeredViaWinRt = true;
            return;
        }

        var identityStr = ShellSyncRoot.BuildSyncRootId(_accountName);
        FreeSyncRootIdentity();
        var identity = Encoding.Unicode.GetBytes(identityStr + "\0");
        _syncRootIdentityLen = identity.Length;
        _syncRootIdentityPtr = Marshal.AllocHGlobal(identity.Length);
        Marshal.Copy(identity, 0, _syncRootIdentityPtr, identity.Length);

        var registration = new CF_SYNC_REGISTRATION
        {
            StructSize = (uint)Marshal.SizeOf<CF_SYNC_REGISTRATION>(),
            ProviderName = ProviderName,
            ProviderVersion = ProviderVersion,
            SyncRootIdentity = _syncRootIdentityPtr,
            SyncRootIdentityLength = (uint)_syncRootIdentityLen,
            ProviderId = ProviderId,
        };

        var policies = new CF_SYNC_POLICIES
        {
            StructSize = (uint)Marshal.SizeOf<CF_SYNC_POLICIES>(),
            Hydration = new CF_HYDRATION_POLICY
            {
                Primary = CF_HYDRATION_POLICY_PRIMARY.CF_HYDRATION_POLICY_PARTIAL,
                Modifier = CF_HYDRATION_POLICY_MODIFIER.CF_HYDRATION_POLICY_MODIFIER_NONE,
            },
            Population = new CF_POPULATION_POLICY
            {
                Primary = CF_POPULATION_POLICY_PRIMARY.CF_POPULATION_POLICY_PARTIAL,
                Modifier = CF_POPULATION_POLICY_MODIFIER.CF_POPULATION_POLICY_MODIFIER_NONE,
            },
            InSync = CF_INSYNC_POLICY.CF_INSYNC_POLICY_NONE,
            HardLink = CF_HARDLINK_POLICY.CF_HARDLINK_POLICY_NONE,
        };

        CfRegisterSyncRoot(
            SyncRootPath,
            registration,
            policies,
            CF_REGISTER_FLAGS.CF_REGISTER_FLAG_UPDATE | CF_REGISTER_FLAGS.CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT)
            .ThrowIfFailed();
        _registered = true;
        _registeredViaWinRt = false;

        // Cf path already registered — do not call WinRT Register (would double-register).
        var stubId = ShellSyncRoot.BuildSyncRootId(_accountName);
        _shellSyncRootId = stubId;
        _shellDetail = ShellSyncRoot.TryRegisterViaRegistry(SyncRootPath, stubId)
            ? "registry stub (CfRegister path)"
            : "registry stub failed";
    }

    public void UnregisterSyncRoot(string? accountName = null)
    {
        EnsureWindows();
        if (!string.IsNullOrWhiteSpace(accountName))
            _accountName = accountName.Trim();

        Disconnect();

        var account = _accountName ?? "default";
        try
        {
            ShellSyncRoot.TryUnregister(account, out var detail);
            _shellDetail = detail;
        }
        catch { /* best-effort */ }

        if (!_registeredViaWinRt)
        {
            try { CfUnregisterSyncRoot(SyncRootPath).ThrowIfFailed(); }
            catch { /* may already be clean */ }
        }
        // WinRT Unregister (above) also tears down the CfAPI sync root.

        _registered = false;
        _registeredViaWinRt = false;
        _shellSyncRootId = null;
        FreeSyncRootIdentity();

        // Soft-clean leftover placeholder debris when the sync root dir is empty-ish.
        try
        {
            if (Directory.Exists(SyncRootPath))
            {
                foreach (var f in Directory.EnumerateFileSystemEntries(SyncRootPath))
                {
                    try
                    {
                        if (Directory.Exists(f)) Directory.Delete(f, recursive: true);
                        else File.Delete(f);
                    }
                    catch { /* locked / reparse — leave */ }
                }
            }
        }
        catch { /* best-effort */ }
    }

    public void Connect()
    {
        EnsureWindows();
        if (!_registered)
            throw new InvalidOperationException("RegisterSyncRoot first.");
        if (_connected) return;

        _fetchData = OnFetchData;
        _cancelFetch = OnCancelFetchData;
        _notifyClose = OnNotifyFileClose;
        _notifyDelete = OnNotifyDelete;
        _notifyRename = OnNotifyRename;
        _callbackTable = new[]
        {
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_DATA,
                Callback = _fetchData,
            },
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_CANCEL_FETCH_DATA,
                Callback = _cancelFetch,
            },
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION,
                Callback = _notifyClose,
            },
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_DELETE,
                Callback = _notifyDelete,
            },
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_RENAME,
                Callback = _notifyRename,
            },
            CF_CALLBACK_REGISTRATION.CF_CALLBACK_REGISTRATION_END,
        };

        if (_selfHandle.IsAllocated) _selfHandle.Free();
        _selfHandle = GCHandle.Alloc(this);

        CfConnectSyncRoot(
            SyncRootPath,
            _callbackTable,
            GCHandle.ToIntPtr(_selfHandle),
            CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
            out _connectionKey).ThrowIfFailed();
        _connected = true;
    }

    public void Disconnect()
    {
        if (!_connected) return;
        try { CfDisconnectSyncRoot(_connectionKey).ThrowIfFailed(); }
        catch { /* best-effort */ }
        _connected = false;
        _connectionKey = default;
        if (_selfHandle.IsAllocated) _selfHandle.Free();
        _callbackTable = null;
        _fetchData = null;
        _cancelFetch = null;
        _notifyClose = null;
        _notifyDelete = null;
        _notifyRename = null;
    }

    public void AttachSession(VaultSession session) => Session = session;

    /// <summary>
    /// Creates on-demand placeholders under the sync root for the given vault nodes.
    /// FileIdentity = UTF-8 cleartext path (e.g. /hello.txt) used by FETCH_DATA.
    /// Nested RelativeFileName may contain '\' — create parents (dirs) before children.
    /// </summary>
    public int CreatePlaceholders(IReadOnlyList<CloudFilesPlaceholder> placeholders)
    {
        EnsureWindows();
        if (!_registered)
            throw new InvalidOperationException("RegisterSyncRoot first.");
        if (placeholders.Count == 0) return 0;

        // Create by depth so parent dir placeholders exist before children.
        var ordered = placeholders
            .OrderBy(p => p.CleartextRelativePath.Count(c => c is '/' or '\\'))
            .ThenBy(p => p.IsDirectory ? 0 : 1)
            .ThenBy(p => p.CleartextRelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var total = 0;
        foreach (var depthGroup in ordered.GroupBy(p => p.CleartextRelativePath.Count(c => c is '/' or '\\')))
        {
            foreach (var item in depthGroup)
            {
                try
                {
                    total += CreatePlaceholderBatch(new[] { item });
                }
                catch (Exception ex)
                {
                    // Skip invalid names / oversized paths rather than aborting the whole populate.
                    System.Diagnostics.Debug.WriteLine(
                        "CreatePlaceholder skipped " + item.CleartextRelativePath + ": " + ex.Message);
                }
            }
        }
        return total;
    }

    private int CreatePlaceholderBatch(IReadOnlyList<CloudFilesPlaceholder> placeholders)
    {
        // One item at a time from CreatePlaceholders; BaseDirectoryPath = parent folder.
        if (placeholders.Count != 1)
            throw new ArgumentException("CreatePlaceholderBatch expects a single item.");

        var p = placeholders[0];
        var rel = p.CleartextRelativePath.Replace('\\', '/').TrimStart('/');
        var slash = rel.LastIndexOf('/');
        var parentRel = slash >= 0 ? rel[..slash] : "";
        var leaf = slash >= 0 ? rel[(slash + 1)..] : rel;
        var baseDir = string.IsNullOrEmpty(parentRel)
            ? SyncRootPath
            : Path.Combine(SyncRootPath, parentRel.Replace('/', Path.DirectorySeparatorChar));

        var pins = new List<IntPtr>();
        try
        {
            var identityBytes = Encoding.UTF8.GetBytes("/" + rel);
            var idPtr = Marshal.AllocHGlobal(identityBytes.Length);
            pins.Add(idPtr);
            Marshal.Copy(identityBytes, 0, idPtr, identityBytes.Length);

            var basic = new FILE_BASIC_INFO
            {
                FileAttributes = p.IsDirectory
                    ? FileFlagsAndAttributes.FILE_ATTRIBUTE_DIRECTORY
                    : FileFlagsAndAttributes.FILE_ATTRIBUTE_NORMAL,
            };

            var infos = new[]
            {
                new CF_PLACEHOLDER_CREATE_INFO
                {
                    RelativeFileName = leaf.Replace('/', '\\'),
                    FsMetadata = new CF_FS_METADATA
                    {
                        BasicInfo = basic,
                        FileSize = p.IsDirectory ? 0 : (p.FileSize ?? 0),
                    },
                    FileIdentity = idPtr,
                    FileIdentityLength = (uint)identityBytes.Length,
                    Flags = CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC,
                },
            };

            CfCreatePlaceholders(
                baseDir,
                infos,
                1,
                CF_CREATE_FLAGS.CF_CREATE_FLAG_NONE,
                out var processed).ThrowIfFailed();
            return (int)processed;
        }
        finally
        {
            foreach (var ptr in pins)
                Marshal.FreeHGlobal(ptr);
        }
    }

    /// <summary>
    /// Lists vault files/dirs (recursive) and creates matching placeholders.
    /// Directory placeholders are created before nested files.
    /// </summary>
    public async Task<int> PopulateRootPlaceholdersAsync(CancellationToken ct = default)
    {
        if (Session is null)
            throw new InvalidOperationException("AttachSession first.");

        var entries = await Session.ListAsync("/", recursive: true, ct).ConfigureAwait(false);
        var list = new List<CloudFilesPlaceholder>();
        var seenDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var e in entries)
        {
            if (e.Contains(" ->", StringComparison.Ordinal)) continue; // symlink display
            var isDir = e.EndsWith("/", StringComparison.Ordinal);
            var full = (isDir ? e.TrimEnd('/') : e).TrimStart('/');
            if (string.IsNullOrEmpty(full)) continue;

            // Ensure every parent directory has a placeholder.
            var parts = full.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
            var accum = "";
            for (var i = 0; i < parts.Length - (isDir ? 0 : 1); i++)
            {
                accum = string.IsNullOrEmpty(accum) ? parts[i] : accum + "/" + parts[i];
                if (seenDirs.Add(accum))
                {
                    list.Add(new CloudFilesPlaceholder
                    {
                        CleartextRelativePath = accum,
                        CiphertextKey = "",
                        IsDirectory = true,
                        FileSize = 0,
                    });
                }
            }

            if (isDir)
            {
                if (seenDirs.Add(full))
                {
                    list.Add(new CloudFilesPlaceholder
                    {
                        CleartextRelativePath = full,
                        CiphertextKey = "",
                        IsDirectory = true,
                        FileSize = 0,
                    });
                }
                continue;
            }

            long? size = null;
            try
            {
                var bytes = await Session.CatAsync("/" + full, ct).ConfigureAwait(false);
                size = bytes.LongLength;
            }
            catch
            {
                size = 0;
            }

            list.Add(new CloudFilesPlaceholder
            {
                CleartextRelativePath = full,
                CiphertextKey = "",
                IsDirectory = false,
                FileSize = size,
            });
        }

        return CreatePlaceholders(list);
    }

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
            CfGetPlatformInfo(out var info).ThrowIfFailed();
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
        ShellSyncRootId = _shellSyncRootId,
        ShellRegistration = _shellDetail,
        WinRtShell = ShellSyncRoot.SupportsWinRt,
    };

    public void Dispose()
    {
        try { Disconnect(); } catch { /* ignore */ }
        FreeSyncRootIdentity();
        GC.SuppressFinalize(this);
    }

    private void EnsureWindows()
    {
        if (!IsWindowsCloudFilesAvailable)
            throw new PlatformNotSupportedException("CfAPI requires Windows 10 1803+.");
    }

    private void FreeSyncRootIdentity()
    {
        if (_syncRootIdentityPtr != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_syncRootIdentityPtr);
            _syncRootIdentityPtr = IntPtr.Zero;
            _syncRootIdentityLen = 0;
        }
    }

    private static CloudFilesProvider? FromContext(in CF_CALLBACK_INFO info)
    {
        if (info.CallbackContext == IntPtr.Zero) return null;
        var gch = GCHandle.FromIntPtr(info.CallbackContext);
        return gch.IsAllocated ? gch.Target as CloudFilesProvider : null;
    }

    private static string? ReadFileIdentityPath(in CF_CALLBACK_INFO info)
    {
        if (info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0)
            return null;
        var bytes = new byte[info.FileIdentityLength];
        Marshal.Copy(info.FileIdentity, bytes, 0, bytes.Length);
        return Encoding.UTF8.GetString(bytes);
    }

    private static void OnFetchData(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        var provider = FromContext(info);
        try
        {
            var path = ReadFileIdentityPath(info)
                ?? throw new InvalidOperationException("missing FileIdentity");
            if (provider?.Session is null)
                throw new InvalidOperationException("no vault session");

            var clear = provider.Session.CatAsync(path).GetAwaiter().GetResult();
            try
            {
                var offset = parameters.FetchData.RequiredFileOffset;
                var length = parameters.FetchData.RequiredLength;
                if (offset < 0 || offset > clear.LongLength)
                    throw new InvalidOperationException("bad fetch offset");
                var available = clear.LongLength - offset;
                var toSend = (long)Math.Min((ulong)available, length > 0 ? (ulong)length : (ulong)available);
                if (toSend < 0) toSend = 0;

                var slice = new byte[toSend];
                try
                {
                    if (toSend > 0)
                        Buffer.BlockCopy(clear, (int)offset, slice, 0, (int)toSend);

                    var handle = GCHandle.Alloc(slice, GCHandleType.Pinned);
                    try
                    {
                        var opInfo = new CF_OPERATION_INFO
                        {
                            StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                            Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
                            ConnectionKey = info.ConnectionKey,
                            TransferKey = info.TransferKey,
                        };
                        var opParams = CF_OPERATION_PARAMETERS.Create(
                            new CF_OPERATION_PARAMETERS.TRANSFERDATA
                            {
                                Flags = CF_OPERATION_TRANSFER_DATA_FLAGS.CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                                CompletionStatus = NTStatus.STATUS_SUCCESS,
                                Buffer = handle.AddrOfPinnedObject(),
                                Offset = offset,
                                Length = toSend,
                            });
                        CfExecute(opInfo, ref opParams).ThrowIfFailed();
                    }
                    finally
                    {
                        handle.Free();
                    }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(slice);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(clear);
            }
        }
        catch (Exception)
        {
            try
            {
                var opInfo = new CF_OPERATION_INFO
                {
                    StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                    Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
                    ConnectionKey = info.ConnectionKey,
                    TransferKey = info.TransferKey,
                };
                var opParams = CF_OPERATION_PARAMETERS.Create(
                    new CF_OPERATION_PARAMETERS.TRANSFERDATA
                    {
                        Flags = CF_OPERATION_TRANSFER_DATA_FLAGS.CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
                        CompletionStatus = new NTStatus(unchecked((int)0xC000CF18)),
                        Buffer = IntPtr.Zero,
                        Offset = parameters.FetchData.RequiredFileOffset,
                        Length = 0,
                    });
                CfExecute(opInfo, ref opParams);
            }
            catch { /* fail closed */ }
        }
    }

    private static void OnCancelFetchData(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        _ = info;
        _ = parameters;
    }

    private static void OnNotifyFileClose(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        // Durable writes must go through AcknowledgeWriteOnlyIfRemoteOk(true) after remote 2xx.
        _ = info;
        _ = parameters;
    }

    /// <summary>
    /// Fail-closed delete: ACK with ACCESS_DENIED until vault DeleteAsync is wired to remote 2xx.
    /// TODO: after remote delete 2xx, ACK with STATUS_SUCCESS (and optionally mutate vault).
    /// </summary>
    private static void OnNotifyDelete(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        _ = parameters;
        try
        {
            var opInfo = new CF_OPERATION_INFO
            {
                StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_ACK_DELETE,
                ConnectionKey = info.ConnectionKey,
                TransferKey = info.TransferKey,
            };
            var opParams = CF_OPERATION_PARAMETERS.Create(
                new CF_OPERATION_PARAMETERS.ACKDELETE
                {
                    Flags = CF_OPERATION_ACK_DELETE_FLAGS.CF_OPERATION_ACK_DELETE_FLAG_NONE,
                    CompletionStatus = StatusCloudFileAccessDenied,
                });
            CfExecute(opInfo, ref opParams);
        }
        catch { /* fail closed */ }
    }

    /// <summary>
    /// Fail-closed rename: ACK with ACCESS_DENIED until vault rename/move is wired to remote 2xx.
    /// TODO: after remote rename 2xx, ACK with STATUS_SUCCESS.
    /// </summary>
    private static void OnNotifyRename(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        _ = parameters;
        try
        {
            var opInfo = new CF_OPERATION_INFO
            {
                StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_ACK_RENAME,
                ConnectionKey = info.ConnectionKey,
                TransferKey = info.TransferKey,
            };
            var opParams = CF_OPERATION_PARAMETERS.Create(
                new CF_OPERATION_PARAMETERS.ACKRENAME
                {
                    Flags = CF_OPERATION_ACK_RENAME_FLAGS.CF_OPERATION_ACK_RENAME_FLAG_NONE,
                    CompletionStatus = StatusCloudFileAccessDenied,
                });
            CfExecute(opInfo, ref opParams);
        }
        catch { /* fail closed */ }
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
    public string? ShellSyncRootId { get; init; }
    public string? ShellRegistration { get; init; }
    public bool WinRtShell { get; init; }
}

public sealed class CloudFilesPlaceholder
{
    public required string CleartextRelativePath { get; init; }
    public required string CiphertextKey { get; init; }
    public bool IsDirectory { get; init; }
    public long? FileSize { get; init; }
}






