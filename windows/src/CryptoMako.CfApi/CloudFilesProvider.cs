using System.Runtime.InteropServices;
using System.Text;
using CryptoMako.App;
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
/// Fail-closed: write/delete/rename notify ACK SUCCESS only after vault mutation (remote 2xx).
/// </summary>
public sealed class CloudFilesProvider : IDisposable, IExplorerViewer
{
    public const string ProviderName = "CryptoMako";
    public const string ProviderVersion = "0.1.0";
    public const string SyncRootIdPrefix = "CryptoMako!";
    public static readonly Guid ProviderId = new("C8A7E5D1-4B2F-4E9A-9C31-7F6D2A1B0E44");

    // STATUS_CLOUD_FILE_ACCESS_DENIED â€” fail-closed ACK when vault/remote mutation fails.
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
    private CF_CALLBACK? _fetchPlaceholders;
    private CF_CALLBACK? _cancelFetchPlaceholders;
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
        // Do not CfRegisterSyncRoot after a successful WinRT register (double-register â†’ invalid).
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

        // Align with WinRT path: partial hydrate, auto-dehydrate, Full population.
        var policies = BuildCfSyncPolicies();

        CfRegisterSyncRoot(
            SyncRootPath,
            registration,
            policies,
            CF_REGISTER_FLAGS.CF_REGISTER_FLAG_UPDATE | CF_REGISTER_FLAGS.CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT)
            .ThrowIfFailed();
        _registered = true;
        _registeredViaWinRt = false;

        // Cf path already registered â€” do not call WinRT Register (would double-register).
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
                    catch { /* locked / reparse â€” leave */ }
                }
            }
        }
        catch { /* best-effort */ }
    }

    /// <summary>
    /// Clears orphan CfAPI / WinRT / registry sync-root state for this path before a fresh Register.
    /// Call when in-process state says unregistered but Explorer still treats the folder as a cloud root.
    /// </summary>
    public string CleanupOrphans(string accountName = "default")
    {
        EnsureWindows();
        if (!string.IsNullOrWhiteSpace(accountName))
            _accountName = accountName.Trim();
        Disconnect();
        var detail = ShellSyncRoot.TryCleanupOrphans(SyncRootPath, _accountName ?? "default");
        _registered = false;
        _registeredViaWinRt = false;
        _shellSyncRootId = null;
        _shellDetail = detail;
        FreeSyncRootIdentity();
        return detail;
    }

    public void Connect()
    {
        EnsureWindows();
        if (!_registered)
            throw new InvalidOperationException("RegisterSyncRoot first.");
        if (_connected) return;

        _fetchData = OnFetchData;
        _cancelFetch = OnCancelFetchData;
        _fetchPlaceholders = OnFetchPlaceholders;
        _cancelFetchPlaceholders = OnCancelFetchPlaceholders;
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
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS,
                Callback = _fetchPlaceholders,
            },
            new CF_CALLBACK_REGISTRATION
            {
                Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS,
                Callback = _cancelFetchPlaceholders,
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

        // Keep _callbackTable + CF_CALLBACK fields rooted for the connection lifetime.
        // (Cannot GCHandle.Pinned ? the array holds managed delegates.)
        CfConnectSyncRoot(
            SyncRootPath,
            _callbackTable,
            GCHandle.ToIntPtr(_selfHandle),
            CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH
                | CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO,
            out _connectionKey).ThrowIfFailed();
        _connected = true;

        // Advertise idle/connected so shell/query paths see a live provider.
        try
        {
            CfUpdateSyncProviderStatus(
                _connectionKey,
                CF_SYNC_PROVIDER_STATUS.CF_PROVIDER_STATUS_IDLE).ThrowIfFailed();
        }
        catch { /* best-effort; status is advisory */ }
    }

    /// <inheritdoc />
    public bool IsConnected => _connected;

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
        _fetchPlaceholders = null;
        _cancelFetchPlaceholders = null;
        _notifyClose = null;
        _notifyDelete = null;
        _notifyRename = null;
    }

    public void AttachSession(VaultSession session) => Session = session;

    /// <summary>
    /// Creates on-demand placeholders under the sync root for the given vault nodes.
    /// FileIdentity = UTF-8 cleartext path (e.g. /hello.txt) used by FETCH_DATA.
    /// Nested RelativeFileName may contain '\' â€” create parents (dirs) before children.
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
    /// Seeds placeholders under the sync root.
    /// Default recursive=false lists only "/" (one level); nested dirs fill via FETCH_PLACEHOLDERS.
    /// </summary>
    public async Task<int> PopulateRootPlaceholdersAsync(bool recursive = false, CancellationToken ct = default)
    {
        if (Session is null)
            throw new InvalidOperationException("AttachSession first.");

        var entries = await Session.ListAsync("/", recursive: recursive, ct).ConfigureAwait(false);
        var list = new List<CloudFilesPlaceholder>();
        var seenDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var e in entries)
        {
            if (e.Contains(" ->", StringComparison.Ordinal)) continue; // symlink display
            var isDir = e.EndsWith("/", StringComparison.Ordinal);
            // recursive ListAsync yields "/a/b"; non-recursive yields "a" / "b/" relative names.
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

            // Do NOT CatAsync here — downloading every root file for size stalls Connect,
            // contends with Backup Sync / FETCH_DATA, and can leave Explorer on an empty root.
            // Placeholder size 0 is fine; FETCH_DATA supplies real bytes on hydrate.
            list.Add(new CloudFilesPlaceholder
            {
                CleartextRelativePath = full,
                CiphertextKey = "",
                IsDirectory = false,
                FileSize = 0,
            });
        }

        return CreatePlaceholders(list);
    }

    /// <summary>
    /// Sync-root policy summary (WinRT + CfRegister). Partial hydrate; Full population.
    /// MSDN: CF_POPULATION_POLICY_PARTIAL is not supported ? it left external ENUM at 0x8007016A
    /// while the provider process could still list placeholders. AlwaysFull blocks
    /// CfCreatePlaceholders (INVALID_REQUEST). Full is supported; seed placeholders after
    /// AttachSession+Connect, and never open Explorer until cross-process ENUM succeeds.
    /// </summary>
    public const string SyncPolicySummary =
        "hydration=Partial; hydrationModifier=AutoDehydrationAllowed; " +
        "population=Full; pin=AllowPinning; hardlink=None";

    public static CF_SYNC_POLICIES BuildCfSyncPolicies() => new()
    {
        StructSize = (uint)Marshal.SizeOf<CF_SYNC_POLICIES>(),
        Hydration = new CF_HYDRATION_POLICY
        {
            Primary = CF_HYDRATION_POLICY_PRIMARY.CF_HYDRATION_POLICY_PARTIAL,
            Modifier = CF_HYDRATION_POLICY_MODIFIER.CF_HYDRATION_POLICY_MODIFIER_AUTO_DEHYDRATION_ALLOWED,
        },
        Population = new CF_POPULATION_POLICY
        {
            Primary = CF_POPULATION_POLICY_PRIMARY.CF_POPULATION_POLICY_FULL,
            Modifier = CF_POPULATION_POLICY_MODIFIER.CF_POPULATION_POLICY_MODIFIER_NONE,
        },
        InSync = CF_INSYNC_POLICY.CF_INSYNC_POLICY_NONE,
        HardLink = CF_HARDLINK_POLICY.CF_HARDLINK_POLICY_NONE,
    };

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
        PolicySummary = SyncPolicySummary,
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

            // Offload vault I/O so CfAPI filter threads are not pinned on S3 awaits
            // (deadlocks / starvation with Backup Sync workers on the same HttpClient).
            var session = provider.Session;
            var clear = Task.Run(
                    () => session.CatAsync(path).ConfigureAwait(false).GetAwaiter().GetResult())
                .GetAwaiter().GetResult();
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

    private static void OnCancelFetchPlaceholders(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        _ = info;
        _ = parameters;
    }

    /// <summary>
    /// Builds one-level child placeholders under <paramref name="parentVaultPath"/> from
    /// <see cref="VaultSession.ListAsync"/> non-recursive entries (names like "a.txt" / "dir/").
    /// </summary>
    public static IReadOnlyList<CloudFilesPlaceholder> BuildImmediateChildPlaceholders(
        string parentVaultPath,
        IEnumerable<string> listEntries,
        string? pattern = null)
    {
        var parent = NormalizeVaultCleartextPath(parentVaultPath);
        var parentRel = parent == "/" ? "" : parent.TrimStart('/');
        var list = new List<CloudFilesPlaceholder>();
        foreach (var e in listEntries)
        {
            if (string.IsNullOrWhiteSpace(e)) continue;
            if (e.Contains(" ->", StringComparison.Ordinal)) continue;
            var isDir = e.EndsWith("/", StringComparison.Ordinal);
            var name = (isDir ? e.TrimEnd('/') : e).Trim().TrimStart('/', '\\');
            if (string.IsNullOrEmpty(name) || name.Contains('/') || name.Contains('\\'))
                continue;
            if (!MatchesFetchPattern(name, pattern))
                continue;
            var full = string.IsNullOrEmpty(parentRel) ? name : parentRel + "/" + name;
            list.Add(new CloudFilesPlaceholder
            {
                CleartextRelativePath = full,
                CiphertextKey = "",
                IsDirectory = isDir,
                FileSize = isDir ? 0 : null,
            });
        }
        return list;
    }

    /// <summary>True when <paramref name="fileName"/> matches CfAPI FETCH_PLACEHOLDERS Pattern (* supported).</summary>
    public static bool MatchesFetchPattern(string fileName, string? pattern)
    {
        if (string.IsNullOrWhiteSpace(pattern) || pattern == "*")
            return true;
        var p = pattern.Trim();
        if (p.StartsWith('*') && p.EndsWith('*') && p.Length >= 2)
            return fileName.Contains(p.Trim('*'), StringComparison.OrdinalIgnoreCase);
        if (p.StartsWith('*'))
            return fileName.EndsWith(p[1..], StringComparison.OrdinalIgnoreCase);
        if (p.EndsWith('*'))
            return fileName.StartsWith(p[..^1], StringComparison.OrdinalIgnoreCase);
        return fileName.Equals(p, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Lists one vault directory level into placeholder descriptors (no CatAsync).
    /// Returns false on missing session/path or list failure (caller must fail-close TRANSFER).
    /// Empty vault directories return true with an empty list.
    /// </summary>
    public static bool TryListImmediatePlaceholders(
        VaultSession? session,
        string? directoryCleartextPath,
        out IReadOnlyList<CloudFilesPlaceholder> placeholders,
        string? pattern = null)
    {
        placeholders = Array.Empty<CloudFilesPlaceholder>();
        if (session is null || string.IsNullOrWhiteSpace(directoryCleartextPath))
            return false;
        try
        {
            var parent = NormalizeVaultCleartextPath(directoryCleartextPath);
            // Offload await continuations off the CfAPI callback thread when callers use GetResult.
            var entries = Task.Run(
                    () => session.ListAsync(parent, recursive: false).ConfigureAwait(false).GetAwaiter().GetResult())
                .GetAwaiter().GetResult();
            placeholders = BuildImmediateChildPlaceholders(parent, entries, pattern);
            return true;
        }
        catch
        {
            placeholders = Array.Empty<CloudFilesPlaceholder>();
            return false;
        }
    }

    /// <summary>Compat overload — empty on failure (prefer the bool-returning form for FETCH).</summary>
    public static IReadOnlyList<CloudFilesPlaceholder> TryListImmediatePlaceholders(
        VaultSession? session,
        string? directoryCleartextPath,
        string? pattern = null)
    {
        TryListImmediatePlaceholders(session, directoryCleartextPath, out var placeholders, pattern);
        return placeholders;
    }

    /// <summary>
    /// FETCH_PLACEHOLDERS: transfer one directory level from the vault session, then disable
    /// on-demand population for that folder (avoids repeated Explorer callbacks). Child directories
    /// keep on-demand population so expanding them triggers another FETCH_PLACEHOLDERS.
    /// </summary>
    private static void OnFetchPlaceholders(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        var provider = FromContext(info);
        var pattern = parameters.FetchPlaceholders.Pattern;
        // Sync-root FileIdentity is often the provider Context / SyncRootId ("CryptoMako!SID!account"),
        // not a vault path. ResolveVaultPathFromCallback must reject that or we TRANSFER 0 children
        // with DISABLE_ON_DEMAND and Explorer stays empty forever.
        var dirPath = provider?.ResolveVaultPathFromCallback(info) ?? "/";
        var isSyncRoot = dirPath == "/";

        // SyncRoot FETCH must NOT CfExecute(TRANSFER_PLACEHOLDERS). Empirically any TRANSFER on the
        // sync-root folder (with or without DISABLE_ON_DEMAND) flips cross-process ENUM to
        // 0x8007016A while in-proc listing of CfCreatePlaceholders children still works.
        // Seed the root via PopulateRootPlaceholdersAsync / CreatePlaceholders instead; nested
        // directories still use TRANSFER normally.
        if (isSyncRoot)
        {
            TransferPlaceholders(
                info,
                Array.Empty<CloudFilesPlaceholder>(),
                success: true,
                disableOnDemand: false);
            return;
        }

        IReadOnlyList<CloudFilesPlaceholder> children = Array.Empty<CloudFilesPlaceholder>();
        var ok = false;
        var disableOnDemand = true;
        try
        {
            if (provider?.Session is null)
            {
                ok = true;
                disableOnDemand = false;
                children = Array.Empty<CloudFilesPlaceholder>();
            }
            else
            {
                ok = TryListImmediatePlaceholders(provider.Session, dirPath, out children, pattern);
                if (!ok)
                    disableOnDemand = false;
            }
        }
        catch
        {
            ok = false;
            disableOnDemand = false;
            children = Array.Empty<CloudFilesPlaceholder>();
        }

        TransferPlaceholders(info, children, success: ok, disableOnDemand: disableOnDemand);
    }

    private static void TransferPlaceholders(
        in CF_CALLBACK_INFO info,
        IReadOnlyList<CloudFilesPlaceholder> children,
        bool success,
        bool disableOnDemand = true)
    {
        var pins = new List<IntPtr>();
        GCHandle arrayHandle = default;
        try
        {
            var infos = new CF_PLACEHOLDER_CREATE_INFO[children.Count];
            for (var i = 0; i < children.Count; i++)
            {
                var p = children[i];
                var rel = p.CleartextRelativePath.Replace('\\', '/').TrimStart('/');
                var slash = rel.LastIndexOf('/');
                var leaf = slash >= 0 ? rel[(slash + 1)..] : rel;
                var identity = EncodeFileIdentity("/" + rel);
                var idPtr = Marshal.AllocHGlobal(identity.Length);
                pins.Add(idPtr);
                Marshal.Copy(identity, 0, idPtr, identity.Length);

                // Dirs: leave on-demand population enabled (no DISABLE flag) so nested FETCH fires.
                var flags = CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
                infos[i] = new CF_PLACEHOLDER_CREATE_INFO
                {
                    RelativeFileName = leaf.Replace('/', '\\'),
                    FsMetadata = new CF_FS_METADATA
                    {
                        BasicInfo = new FILE_BASIC_INFO
                        {
                            FileAttributes = p.IsDirectory
                                ? FileFlagsAndAttributes.FILE_ATTRIBUTE_DIRECTORY
                                : FileFlagsAndAttributes.FILE_ATTRIBUTE_NORMAL,
                        },
                        FileSize = p.IsDirectory ? 0 : (p.FileSize ?? 0),
                    },
                    FileIdentity = idPtr,
                    FileIdentityLength = (uint)identity.Length,
                    Flags = flags,
                };
            }

            if (infos.Length > 0)
                arrayHandle = GCHandle.Alloc(infos, GCHandleType.Pinned);

            var opInfo = new CF_OPERATION_INFO
            {
                StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS,
                ConnectionKey = info.ConnectionKey,
                TransferKey = info.TransferKey,
            };
            var count = success ? (uint)infos.Length : 0u;
            var opParams = CF_OPERATION_PARAMETERS.Create(
                new CF_OPERATION_PARAMETERS.TRANSFERPLACEHOLDERS
                {
                    Flags = disableOnDemand
                        ? CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAGS.CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION
                        : CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAGS.CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_NONE,
                    CompletionStatus = success ? NTStatus.STATUS_SUCCESS : StatusCloudFileAccessDenied,
                    PlaceholderTotalCount = count,
                    PlaceholderArray = infos.Length > 0 && success
                        ? arrayHandle.AddrOfPinnedObject()
                        : IntPtr.Zero,
                    PlaceholderCount = success ? count : 0,
                    EntriesProcessed = 0,
                });
            CfExecute(opInfo, ref opParams);
        }
        catch
        {
            try
            {
                var opInfo = new CF_OPERATION_INFO
                {
                    StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                    Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS,
                    ConnectionKey = info.ConnectionKey,
                    TransferKey = info.TransferKey,
                };
                var opParams = CF_OPERATION_PARAMETERS.Create(
                    new CF_OPERATION_PARAMETERS.TRANSFERPLACEHOLDERS
                    {
                        Flags = CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAGS.CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION,
                        CompletionStatus = StatusCloudFileAccessDenied,
                        PlaceholderTotalCount = 0,
                        PlaceholderArray = IntPtr.Zero,
                        PlaceholderCount = 0,
                        EntriesProcessed = 0,
                    });
                CfExecute(opInfo, ref opParams);
            }
            catch { /* fail closed */ }
        }
        finally
        {
            if (arrayHandle.IsAllocated) arrayHandle.Free();
            foreach (var ptr in pins)
                Marshal.FreeHGlobal(ptr);
        }
    }


    /// <summary>
    /// NOTIFY_FILE_CLOSE_COMPLETION: completion-only (no deny ACK). Write-back hydrated
    /// cleartext â†’ vault put (remote 2xx). On success mark in-sync; on failure leave dirty (fail-closed).
    /// Skips closes flagged DELETED (NOTIFY_DELETE owns vault delete).
    /// </summary>
    private static void OnNotifyFileClose(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        var flags = parameters.CloseCompletion.Flags;
        if ((flags & CF_CALLBACK_CLOSE_COMPLETION_FLAGS.CF_CALLBACK_CLOSE_COMPLETION_FLAG_DELETED) != 0)
            return;

        var provider = FromContext(info);
        if (provider?.Session is null)
            return;

        var vaultPath = provider.ResolveVaultPathFromCallback(info);
        var fsPath = provider.TryResolveAbsoluteFsPath(info);
        if (vaultPath is null || fsPath is null)
            return;
        if (!File.Exists(fsPath) || Directory.Exists(fsPath))
            return;

        byte[]? clear = null;
        try
        {
            clear = File.ReadAllBytes(fsPath);
            var ok = TryWriteBackCleartext(provider.Session, vaultPath, clear);
            if (ok)
                TryMarkPlaceholderInSync(fsPath);
            // No CfExecute ACK for CLOSE completion â€” fail-closed means do not mark durable/in-sync.
        }
        catch
        {
            /* fail closed: leave placeholder dirty */
        }
        finally
        {
            if (clear is not null)
                CryptographicOperations.ZeroMemory(clear);
        }
    }

    /// <summary>
    /// Maps a Windows filesystem path under the sync root to a vault cleartext path ("/a/b").
    /// Returns null when the path is missing, outside the sync root, or is the sync root itself.
    /// </summary>
    public static string? TryMapFsPathToVaultCleartext(string syncRootPath, string? fsPath, string? volumeDosName = null)
    {
        if (string.IsNullOrWhiteSpace(fsPath))
            return null;

        var combined = CombineVolumeRelativePath(volumeDosName, fsPath.Trim());
        string full;
        try { full = Path.GetFullPath(combined); }
        catch { return null; }

        var root = Path.GetFullPath(syncRootPath)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullTrim = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (fullTrim.Equals(root, StringComparison.OrdinalIgnoreCase))
            return null; // never mutate vault for the sync root folder itself

        var rootPrefix = root + Path.DirectorySeparatorChar;
        if (!fullTrim.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
            return null;

        var rel = fullTrim[rootPrefix.Length..].Replace('\\', '/');
        if (string.IsNullOrEmpty(rel) || rel.Contains("..", StringComparison.Ordinal))
            return null;
        return "/" + rel;
    }

    /// <summary>Joins VolumeDosName (e.g. "C:") with a volume-relative path when needed.</summary>
    public static string CombineVolumeRelativePath(string? volumeDosName, string path)
    {
        if (path.Length >= 2 && path[1] == ':')
            return path;
        if (string.IsNullOrWhiteSpace(volumeDosName))
            return path;
        var vol = volumeDosName.TrimEnd('\\', '/');
        if (path.StartsWith('\\') || path.StartsWith('/'))
            return vol + path.Replace('/', '\\');
        return vol + "\\" + path.Replace('/', '\\');
    }

    /// <summary>
    /// Vault delete used by NOTIFY_DELETE. True only when DeleteAsync completed (remote 2xx / local OK).
    /// Directories use recursive:true so Explorer folder deletes stay durable.
    /// </summary>
    public static bool TryDeleteFromVault(VaultSession? session, string? cleartextPath)
    {
        if (session is null || string.IsNullOrWhiteSpace(cleartextPath) || cleartextPath == "/")
            return false;
        try
        {
            session.DeleteAsync(cleartextPath, recursive: true).GetAwaiter().GetResult();
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Vault rename used by NOTIFY_RENAME. True only when RenameAsync completed (remote put+delete OK).
    /// Moves outside the sync root / invalid targets return false (fail-closed).
    /// </summary>
    public static bool TryRenameInVault(VaultSession? session, string? fromCleartext, string? toCleartext)
    {
        if (session is null
            || string.IsNullOrWhiteSpace(fromCleartext)
            || string.IsNullOrWhiteSpace(toCleartext)
            || fromCleartext == "/"
            || toCleartext == "/")
            return false;
        try
        {
            session.RenameAsync(fromCleartext, toCleartext).GetAwaiter().GetResult();
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Same gate as writes: never treat delete/rename as durable without remote success.</summary>
    public static void AcknowledgeMutationOnlyIfRemoteOk(bool remoteHttp2xx) =>
        AcknowledgeWriteOnlyIfRemoteOk(remoteHttp2xx);

    private string? ResolveVaultPathFromCallback(in CF_CALLBACK_INFO info)
    {
        var identity = ReadFileIdentityPath(info);
        if (!string.IsNullOrWhiteSpace(identity) && LooksLikeVaultCleartextIdentity(identity))
        {
            var norm = identity.Replace('\\', '/');
            if (!norm.StartsWith('/'))
                norm = "/" + norm.TrimStart('/');
            return NormalizeVaultCleartextPath(norm);
        }

        // Fallback: map NormalizedPath under sync root (REQUIRE_FULL_FILE_PATH → absolute).
        // Sync root itself maps to null here — callers use ?? "/" for FETCH_PLACEHOLDERS.
        var normalized = info.NormalizedPath;
        return TryMapFsPathToVaultCleartext(SyncRootPath, normalized, info.VolumeDosName);
    }

    /// <summary>
    /// True when FileIdentity looks like a vault cleartext path ("/a/b" or "a/b"), not a
    /// SyncRootId / WinRT Context blob ("CryptoMako!SID!account").
    /// </summary>
    public static bool LooksLikeVaultCleartextIdentity(string? identity)
    {
        if (string.IsNullOrWhiteSpace(identity))
            return false;
        var s = identity.Trim().Replace('\\', '/');
        var nul = s.IndexOf('\0');
        if (nul >= 0)
            s = s[..nul];
        if (s.Length == 0)
            return false;
        // Provider sync-root id / WinRT context.
        if (s.StartsWith(SyncRootIdPrefix, StringComparison.OrdinalIgnoreCase))
            return false;
        if (s.Contains('!', StringComparison.Ordinal) && s.Contains("CryptoMako", StringComparison.OrdinalIgnoreCase))
            return false;
        // UTF-16 sync-root id misread as UTF-8 often contains NULs or odd control bytes.
        foreach (var ch in s)
        {
            if (ch == '\0' || (char.IsControl(ch) && ch != '\t'))
                return false;
        }
        if (s == "/")
            return true;
        var body = s.StartsWith('/') ? s[1..] : s;
        if (string.IsNullOrEmpty(body))
            return true;
        foreach (var part in body.Split('/', StringSplitOptions.None))
        {
            if (part.Length == 0 || part == "." || part == "..")
                return false;
        }
        return true;
    }

    /// <summary>
    /// NOTIFY_DELETE: mutate vault (remote 2xx), then ACK SUCCESS; any failure â†’ ACCESS_DENIED.
    /// </summary>
    private static void OnNotifyDelete(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        _ = parameters;
        var provider = FromContext(info);
        var path = provider?.ResolveVaultPathFromCallback(info);
        var ok = TryDeleteFromVault(provider?.Session, path);
        AckDelete(info, ok);
    }

    /// <summary>
    /// NOTIFY_RENAME: mutate vault (remote 2xx), update FileIdentity to the new cleartext path,
    /// then ACK SUCCESS; any vault failure â†’ ACCESS_DENIED.
    /// </summary>
    private static void OnNotifyRename(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        var provider = FromContext(info);
        var from = provider?.ResolveVaultPathFromCallback(info);
        string? to = null;
        if (provider is not null)
        {
            var target = parameters.Rename.TargetPath;
            to = TryMapFsPathToVaultCleartext(provider.SyncRootPath, target, info.VolumeDosName);
        }
        var ok = TryRenameInVault(provider?.Session, from, to);
        if (ok && to is not null && provider is not null)
        {
            // File still at pre-rename FS path during this callback â€” stamp new vault identity now.
            var fsPath = provider.TryResolveAbsoluteFsPath(info);
            if (fsPath is not null)
                TryUpdatePlaceholderFileIdentity(fsPath, to);
        }
        AckRename(info, ok);
    }

    /// <summary>Normalizes vault cleartext identity to "/a/b" form (UTF-8 FileIdentity payload).</summary>
    public static string NormalizeVaultCleartextPath(string cleartextPath)
    {
        var norm = cleartextPath.Replace('\\', '/').Trim();
        if (string.IsNullOrEmpty(norm) || norm == "/")
            return "/";
        if (!norm.StartsWith('/'))
            norm = "/" + norm.TrimStart('/');
        return norm.TrimEnd('/');
    }

    public static byte[] EncodeFileIdentity(string vaultCleartextPath) =>
        Encoding.UTF8.GetBytes(NormalizeVaultCleartextPath(vaultCleartextPath));

    /// <summary>
    /// Opens a placeholder and sets FileIdentity to the vault cleartext path.
    /// Returns false when CfAPI is unavailable or the update fails (non-placeholder, access, etc.).
    /// </summary>
    public static bool TryUpdatePlaceholderFileIdentity(string absoluteFsPath, string vaultCleartextPath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return false;
        if (string.IsNullOrWhiteSpace(absoluteFsPath) || string.IsNullOrWhiteSpace(vaultCleartextPath))
            return false;
        if (vaultCleartextPath == "/")
            return false;

        try
        {
            var identity = EncodeFileIdentity(vaultCleartextPath);
            var openHr = CfOpenFileWithOplock(
                absoluteFsPath,
                CF_OPEN_FILE_FLAGS.CF_OPEN_FILE_FLAG_NONE,
                out var protectedHandle);
            if (openHr.Failed || protectedHandle is null || protectedHandle.IsInvalid)
                return false;

            using (protectedHandle)
            {
                var win32 = CfGetWin32HandleFromProtectedHandle(protectedHandle);
                if (win32 == HFILE.NULL || win32.IsNull)
                    return false;

                var idPtr = Marshal.AllocHGlobal(identity.Length);
                try
                {
                    Marshal.Copy(identity, 0, idPtr, identity.Length);
                    long usn = 0;
                    FileInfo? fi = null;
                    try { fi = new FileInfo(absoluteFsPath); } catch { /* optional metadata */ }
                    var meta = new CF_FS_METADATA
                    {
                        BasicInfo = new FILE_BASIC_INFO
                        {
                            FileAttributes = (fi is not null && (fi.Attributes & FileAttributes.Directory) != 0)
                                ? FileFlagsAndAttributes.FILE_ATTRIBUTE_DIRECTORY
                                : FileFlagsAndAttributes.FILE_ATTRIBUTE_NORMAL,
                        },
                        FileSize = fi?.Length ?? 0,
                    };
                    CfUpdatePlaceholder(
                        win32,
                        meta,
                        idPtr,
                        (uint)identity.Length,
                        Array.Empty<CF_FILE_RANGE>(),
                        0,
                        CF_UPDATE_FLAGS.CF_UPDATE_FLAG_MARK_IN_SYNC,
                        ref usn,
                        IntPtr.Zero).ThrowIfFailed();
                    return true;
                }
                finally
                {
                    Marshal.FreeHGlobal(idPtr);
                }
            }
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Reads placeholder FileIdentity (UTF-8 vault path) when possible. Null if unavailable.
    /// </summary>
    public static string? TryReadPlaceholderFileIdentity(string absoluteFsPath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return null;
        if (string.IsNullOrWhiteSpace(absoluteFsPath))
            return null;
        try
        {
            var openHr = CfOpenFileWithOplock(
                absoluteFsPath,
                CF_OPEN_FILE_FLAGS.CF_OPEN_FILE_FLAG_NONE,
                out var protectedHandle);
            if (openHr.Failed || protectedHandle is null || protectedHandle.IsInvalid)
                return null;
            using (protectedHandle)
            {
                var win32 = CfGetWin32HandleFromProtectedHandle(protectedHandle);
                if (win32 == HFILE.NULL || win32.IsNull)
                    return null;
                // Buffer: BASIC_INFO + identity blob (cap 4 KiB identity)
                const int identityCap = 4096;
                var size = Marshal.SizeOf<CF_PLACEHOLDER_BASIC_INFO>() + identityCap;
                var buf = Marshal.AllocHGlobal(size);
                try
                {
                    var hr = CfGetPlaceholderInfo(
                        win32,
                        CF_PLACEHOLDER_INFO_CLASS.CF_PLACEHOLDER_INFO_BASIC,
                        buf,
                        (uint)size,
                        out var returned);
                    if (hr.Failed || returned == 0)
                        return null;
                    var basic = Marshal.PtrToStructure<CF_PLACEHOLDER_BASIC_INFO>(buf);
                    if (basic.FileIdentityLength == 0)
                        return null;
                    var idOffset = (int)Marshal.OffsetOf<CF_PLACEHOLDER_BASIC_INFO>(nameof(CF_PLACEHOLDER_BASIC_INFO.FileIdentity));
                    var bytes = new byte[basic.FileIdentityLength];
                    Marshal.Copy(IntPtr.Add(buf, idOffset), bytes, 0, bytes.Length);
                    return Encoding.UTF8.GetString(bytes);
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Vault write-back used by NOTIFY_FILE_CLOSE. True only when PutAtCleartextPathAsync completed.
    /// </summary>
    public static bool TryWriteBackCleartext(VaultSession? session, string? cleartextPath, byte[]? cleartextContents)
    {
        if (session is null || cleartextContents is null)
            return false;
        if (string.IsNullOrWhiteSpace(cleartextPath) || cleartextPath == "/")
            return false;
        try
        {
            session.PutAtCleartextPathAsync(cleartextPath, cleartextContents).GetAwaiter().GetResult();
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Re-enables on-demand population for a directory placeholder so the next Explorer
    /// access triggers FETCH_PLACEHOLDERS again (needed after TRANSFER with DISABLE_ON_DEMAND).
    /// </summary>
    public static bool TryEnableOnDemandPopulation(string absoluteFsPath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return false;
        if (string.IsNullOrWhiteSpace(absoluteFsPath))
            return false;
        // Never CfUpdatePlaceholder a CryptoMako sync-root folder itself — Explorer then
        // surfaces 0x8007016A ("The cloud operation is invalid") for the whole location.
        try
        {
            var full = Path.GetFullPath(absoluteFsPath)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var leaf = Path.GetFileName(full);
            var underCm = full.IndexOf(
                Path.DirectorySeparatorChar + "CryptoMako" + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) >= 0
                || full.EndsWith(Path.DirectorySeparatorChar + "CryptoMako", StringComparison.OrdinalIgnoreCase);
            if (underCm && leaf.StartsWith("SyncRoot", StringComparison.OrdinalIgnoreCase))
                return false;
        }
        catch { /* continue to CfAPI attempt for non-CryptoMako paths */ }
        try
        {
            var openHr = CfOpenFileWithOplock(
                absoluteFsPath,
                CF_OPEN_FILE_FLAGS.CF_OPEN_FILE_FLAG_NONE,
                out var protectedHandle);
            if (openHr.Failed || protectedHandle is null || protectedHandle.IsInvalid)
                return false;
            using (protectedHandle)
            {
                var win32 = CfGetWin32HandleFromProtectedHandle(protectedHandle);
                if (win32 == HFILE.NULL || win32.IsNull)
                    return false;
                long usn = 0;
                var meta = new CF_FS_METADATA
                {
                    BasicInfo = new FILE_BASIC_INFO
                    {
                        FileAttributes = FileFlagsAndAttributes.FILE_ATTRIBUTE_DIRECTORY,
                    },
                    FileSize = 0,
                };
                // FileIdentity Length 0 = leave identity unchanged; enable on-demand population.
                CfUpdatePlaceholder(
                    win32,
                    meta,
                    IntPtr.Zero,
                    0,
                    Array.Empty<CF_FILE_RANGE>(),
                    0,
                    CF_UPDATE_FLAGS.CF_UPDATE_FLAG_ENABLE_ON_DEMAND_POPULATION
                        | CF_UPDATE_FLAGS.CF_UPDATE_FLAG_MARK_IN_SYNC,
                    ref usn,
                    IntPtr.Zero).ThrowIfFailed();
                return true;
            }
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Maps a vault cleartext directory to an absolute sync-root filesystem path.
    /// </summary>
    /// <summary>True when absoluteFsPath is the sync root folder (not a child).</summary>
    public bool IsSyncRootFsPath(string? absoluteFsPath)
    {
        if (string.IsNullOrWhiteSpace(absoluteFsPath))
            return false;
        try
        {
            var a = Path.GetFullPath(absoluteFsPath)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var b = Path.GetFullPath(SyncRootPath)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return a.Equals(b, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public string? TryVaultPathToFsPath(string? vaultCleartextPath)
    {
        if (string.IsNullOrWhiteSpace(vaultCleartextPath))
            return null;
        var norm = NormalizeVaultCleartextPath(vaultCleartextPath);
        if (norm == "/")
            return SyncRootPath;
        var rel = norm.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
        try { return Path.GetFullPath(Path.Combine(SyncRootPath, rel)); }
        catch { return null; }
    }

    /// <summary>
    /// Re-lists one vault directory level, creates any missing child placeholders, then
    /// re-enables on-demand population so Explorer can FETCH_PLACEHOLDERS again.
    /// </summary>
    public async Task<int> RefreshDirectoryAsync(string vaultCleartextPath, CancellationToken ct = default)
    {
        EnsureWindows();
        if (!_registered)
            throw new InvalidOperationException("RegisterSyncRoot first.");
        if (Session is null)
            throw new InvalidOperationException("AttachSession first.");

        ct.ThrowIfCancellationRequested();
        var parent = NormalizeVaultCleartextPath(vaultCleartextPath);
        var entries = await Session.ListAsync(parent, recursive: false, ct).ConfigureAwait(false);
        var children = BuildImmediateChildPlaceholders(parent, entries);
        // Best-effort create (existing placeholders may already be present).
        var created = CreatePlaceholders(children);

        var fsPath = TryVaultPathToFsPath(parent);
        // Never CfUpdatePlaceholder the sync-root folder itself — that yields
        // 0x8007016A ("The cloud operation is invalid") for Explorer/enum.
        if (fsPath is not null && !IsSyncRootFsPath(fsPath))
            TryEnableOnDemandPopulation(fsPath);

        return created;
    }

    public static bool TryMarkPlaceholderInSync(string absoluteFsPath)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17134))
            return false;
        if (string.IsNullOrWhiteSpace(absoluteFsPath))
            return false;
        try
        {
            var openHr = CfOpenFileWithOplock(
                absoluteFsPath,
                CF_OPEN_FILE_FLAGS.CF_OPEN_FILE_FLAG_NONE,
                out var protectedHandle);
            if (openHr.Failed || protectedHandle is null || protectedHandle.IsInvalid)
                return false;
            using (protectedHandle)
            {
                var win32 = CfGetWin32HandleFromProtectedHandle(protectedHandle);
                if (win32 == HFILE.NULL || win32.IsNull)
                    return false;
                long usn = 0;
                CfSetInSyncState(
                    win32,
                    CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_IN_SYNC,
                    CF_SET_IN_SYNC_FLAGS.CF_SET_IN_SYNC_FLAG_NONE,
                    ref usn).ThrowIfFailed();
                return true;
            }
        }
        catch
        {
            return false;
        }
    }

    private string? TryResolveAbsoluteFsPath(in CF_CALLBACK_INFO info)
    {
        var combined = CombineVolumeRelativePath(info.VolumeDosName, info.NormalizedPath ?? "");
        if (string.IsNullOrWhiteSpace(combined))
            return null;
        try { return Path.GetFullPath(combined); }
        catch { return null; }
    }

    private static void AckDelete(in CF_CALLBACK_INFO info, bool success)
    {
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
                    CompletionStatus = success ? NTStatus.STATUS_SUCCESS : StatusCloudFileAccessDenied,
                });
            CfExecute(opInfo, ref opParams);
        }
        catch { /* fail closed */ }
    }

    private static void AckRename(in CF_CALLBACK_INFO info, bool success)
    {
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
                    CompletionStatus = success ? NTStatus.STATUS_SUCCESS : StatusCloudFileAccessDenied,
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
    public string? PolicySummary { get; init; }
}

public sealed class CloudFilesPlaceholder
{
    public required string CleartextRelativePath { get; init; }
    public required string CiphertextKey { get; init; }
    public bool IsDirectory { get; init; }
    public long? FileSize { get; init; }
}






