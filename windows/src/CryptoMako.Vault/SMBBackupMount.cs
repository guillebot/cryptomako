using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CryptoMako.Vault;

/// <summary>
/// Mount / remount SMB Backup Sync sources via Windows networking (WNetAddConnection2 / UNC).
/// Never embeds an SMB client. Prefer durable UNC without a drive letter.
/// Mirrors macOS SMBBackupMount behavior (OS mount + fail-closed probes).
/// </summary>
public static class SMBBackupMount
{
    public sealed class MountException : Exception
    {
        public MountException(string message) : base(message) { }
        public MountException(string message, Exception inner) : base(message, inner) { }
    }

    public static string VolumeUnavailableMessage(string path) =>
        $"SMB source unavailable: {path}. Mount the share and retry Sync (fail-closed — nothing was treated as an empty tree).";

    public static string VolumeLostMessage(string path) =>
        $"SMB volume disappeared during Sync: {path}. Sync stopped fail-closed (no wipe / no silent empty-tree success).";

    /// <summary>
    /// Ensure an SMB BackupSource is connected and reachable. Updates Path in place when remounted.
    /// Prefer durable UNC \\host\share[\subpath]; no drive letter is mapped.
    /// </summary>
    public static string EnsureMounted(BackupSource source, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(secrets);

        if (!source.IsSMB)
        {
            if (!IsReachableDirectory(source.Path))
                throw new MountException(VolumeUnavailableMessage(source.Path));
            return source.Path;
        }

        var smb = NormalizedSmbUrl(source);
        var unc = SMBSourceURL.ToUnc(smb);

        if (IsReachableDirectory(unc))
        {
            source.Path = unc;
            source.SmbURL = smb;
            return unc;
        }

        if (!string.IsNullOrWhiteSpace(source.Path) && IsReachableDirectory(source.Path))
        {
            // Already mapped elsewhere (Explorer / net use) — reuse path without force-remount.
            return source.Path;
        }

        var password = LoadPassword(source, secrets)
            ?? throw new MountException(
                "SMB password not found in Credential Manager. Remove the source and add it again.");

        var mounted = Mount(smb, source.SmbUsername, password);
        source.Path = mounted;
        source.SmbURL = smb;
        return mounted;
    }

    /// <summary>
    /// Authenticate and reach \\host\share[\subpath] via WNetAddConnection2 with no local drive letter.
    /// Drive letters are intentionally not used so Sync keeps a stable UNC path and does not steal Z:.
    /// </summary>
    public static string Mount(string smbUrlString, string? username, string password)
    {
        var normalized = SMBSourceURL.Normalize(smbUrlString);
        var shareUnc = SMBSourceURL.ToShareUnc(normalized);
        var fullUnc = SMBSourceURL.ToUnc(normalized);

        if (IsReachableDirectory(fullUnc))
            return fullUnc;

        ConnectShare(shareUnc, username, password);

        if (!IsReachableDirectory(fullUnc))
            throw new MountException(VolumeUnavailableMessage(fullUnc));

        return fullUnc;
    }

    public static void AssertSourceReachable(string path, bool isSMB)
    {
        if (IsReachableDirectory(path))
        {
            // Extra probe: touch directory metadata so a stale DFS/UNC handle still fails closed.
            if (isSMB || LooksLikeNetworkPath(path))
            {
                try
                {
                    _ = Directory.GetFileSystemEntries(path).Take(1).ToArray();
                    var info = new DirectoryInfo(path);
                    _ = info.LastWriteTimeUtc;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException)
                {
                    throw new MountException(VolumeLostMessage($"{path} ({ex.Message})"), ex);
                }
            }
            return;
        }

        if (isSMB || LooksLikeNetworkPath(path))
            throw new MountException(VolumeLostMessage(path));
        throw new MountException(VolumeUnavailableMessage(path));
    }

    public static bool LooksLikeNetworkPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var p = path.Trim();
        return p.StartsWith(@"\\", StringComparison.Ordinal)
               || p.StartsWith("//", StringComparison.Ordinal);
    }

    public static void SavePassword(string password, BackupSource source, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(secrets);
        secrets.SetSecret(source.SmbPasswordAccount, password ?? "");
    }

    public static void DeletePassword(BackupSource source, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(secrets);
        try { secrets.DeleteSecret(source.SmbPasswordAccount); }
        catch { /* best-effort clear */ }
    }

    public static string? LoadPassword(BackupSource source, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(secrets);
        return secrets.GetSecret(source.SmbPasswordAccount);
    }

    public static bool IsReachableDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            return Directory.Exists(path);
        }
        catch
        {
            return false;
        }
    }

    private static string NormalizedSmbUrl(BackupSource source)
    {
        if (!string.IsNullOrWhiteSpace(source.SmbURL))
            return SMBSourceURL.Normalize(source.SmbURL);
        throw new MountException("SMB source is missing smb:// URL.");
    }

    private static void ConnectShare(string shareUnc, string? username, string password)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("SMB Backup mounts require Windows networking.");

        var user = string.IsNullOrWhiteSpace(username) ? null : username.Trim();
        var nr = new NETRESOURCE
        {
            dwType = RESOURCETYPE_DISK,
            lpLocalName = null, // no drive letter — durable UNC only
            lpRemoteName = shareUnc,
            lpProvider = null,
        };

        // CONNECT_UPDATE_PROFILE keeps the connection for this logon session without forcing a letter.
        const int CONNECT_UPDATE_PROFILE = 0x00000001;
        var result = WNetAddConnection2(ref nr, password ?? "", user, CONNECT_UPDATE_PROFILE);

        // Already connected / credentials already present.
        if (result == 0 || result == ERROR_SESSION_CREDENTIAL_CONFLICT || result == ERROR_ALREADY_ASSIGNED)
            return;

        // ERROR_ALREADY_ASSIGNED (85) / SUCCESS — also treat "device already remembered".
        if (result == ERROR_DEVICE_ALREADY_REMEMBERED)
            return;

        throw new MountException(
            $"Could not mount SMB share: {shareUnc} (WNetAddConnection2 status {result}: {Win32Message(result)})");
    }

    private static string Win32Message(int code)
    {
        try { return new Win32Exception(code).Message; }
        catch { return "unknown"; }
    }

    private const int RESOURCETYPE_DISK = 0x00000001;
    private const int ERROR_ALREADY_ASSIGNED = 85;
    private const int ERROR_DEVICE_ALREADY_REMEMBERED = 1202;
    private const int ERROR_SESSION_CREDENTIAL_CONFLICT = 1219;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NETRESOURCE
    {
        public int dwScope;
        public int dwType;
        public int dwDisplayType;
        public int dwUsage;
        public string? lpLocalName;
        public string? lpRemoteName;
        public string? lpComment;
        public string? lpProvider;
    }

    [DllImport("mpr.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int WNetAddConnection2(
        ref NETRESOURCE netResource,
        string? password,
        string? username,
        int flags);
}
