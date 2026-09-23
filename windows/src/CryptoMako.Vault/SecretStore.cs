using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using System.Text.Json;

namespace CryptoMako.Vault;

/// <summary>
/// Secret lookup/store. Never write secrets to settings.json.
/// Windows: Credential Manager. Elsewhere: chmod 600 JSON under ~/.config/cryptomako/.
/// Environment variables always override for CI.
/// </summary>
public interface ISecretStore
{
    string? GetSecret(string account);
    void SetSecret(string account, string value);
    void DeleteSecret(string account);
    bool IsPersistent { get; }
}

public static class SecretAccounts
{
    public const string Password = "CRYPTOMAKO_PASSWORD";
    public const string SecretKey = "CRYPTOMAKO_SECRET_KEY";
    public const string ProxyPassword = "CRYPTOMAKO_PROXY_PASSWORD";
    public const string ServiceName = "CryptoMako";
}

public sealed class EnvSecretStore : ISecretStore
{
    public bool IsPersistent => false;

    public string? GetSecret(string account)
    {
        var value = Environment.GetEnvironmentVariable(account);
        return string.IsNullOrEmpty(value) ? null : value;
    }

    public void SetSecret(string account, string value) =>
        Environment.SetEnvironmentVariable(account, value);

    public void DeleteSecret(string account) =>
        Environment.SetEnvironmentVariable(account, null);
}

/// <summary>Dev-host persistence on macOS/Linux (mode 600). Not used on Windows.</summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _path;

    public FileSecretStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config", "cryptomako", "secrets.json");
    }

    public bool IsPersistent => true;

    public string? GetSecret(string account)
    {
        var map = Load();
        return map.TryGetValue(account, out var v) && !string.IsNullOrEmpty(v) ? v : null;
    }

    public void SetSecret(string account, string value)
    {
        var map = Load();
        map[account] = value;
        Save(map);
    }

    public void DeleteSecret(string account)
    {
        var map = Load();
        if (map.Remove(account))
            Save(map);
    }

    private Dictionary<string, string> Load()
    {
        try
        {
            if (!File.Exists(_path)) return new(StringComparer.Ordinal);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path))
                ?? new(StringComparer.Ordinal);
        }
        catch
        {
            return new(StringComparer.Ordinal);
        }
    }

    private void Save(Dictionary<string, string> map)
    {
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);
        var json = JsonSerializer.Serialize(map, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(_path, json);
        try
        {
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(_path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch
        {
            // Best-effort permissions.
        }
    }
}

/// <summary>
/// Windows Credential Manager (GENERIC). Compiles on all OSes; methods no-op / throw
/// when not running on Windows so macOS `dotnet test` stays green.
/// </summary>
public sealed class WindowsCredentialStore : ISecretStore
{
    public bool IsPersistent => OperatingSystem.IsWindows();

    public static bool IsSupported => OperatingSystem.IsWindows();

    public string? GetSecret(string account)
    {
        if (!OperatingSystem.IsWindows())
            return null;
        return Native.CredRead(Target(account));
    }

    public void SetSecret(string account, string value)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("Windows Credential Manager requires Windows.");
        Native.CredWrite(Target(account), value);
    }

    public void DeleteSecret(string account)
    {
        if (!OperatingSystem.IsWindows())
            return;
        Native.CredDelete(Target(account));
    }

    private static string Target(string account) => $"{SecretAccounts.ServiceName}/{account}";

    private static class Native
    {
        private const int CredTypeGeneric = 1;
        private const int CredPersistLocalMachine = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string? Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string? TargetAlias;
            public string? UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWriteW(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredReadW(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDeleteW(string target, int type, int flags);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern void CredFree(IntPtr buffer);

        [SupportedOSPlatform("windows")]
        public static void CredWrite(string target, string secret)
        {
            var bytes = Encoding.UTF8.GetBytes(secret);
            var blob = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, blob, bytes.Length);
                var cred = new CREDENTIAL
                {
                    Type = CredTypeGeneric,
                    TargetName = target,
                    CredentialBlobSize = bytes.Length,
                    CredentialBlob = blob,
                    Persist = CredPersistLocalMachine,
                    UserName = Environment.UserName,
                };
                if (!CredWriteW(ref cred, 0))
                    throw new InvalidOperationException($"CredWrite failed: {Marshal.GetLastWin32Error()}");
            }
            finally
            {
                Marshal.FreeHGlobal(blob);
            }
        }

        [SupportedOSPlatform("windows")]
        public static string? CredRead(string target)
        {
            if (!CredReadW(target, CredTypeGeneric, 0, out var ptr) || ptr == IntPtr.Zero)
                return null;
            try
            {
                var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
                if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize <= 0)
                    return null;
                var bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
                return Encoding.UTF8.GetString(bytes);
            }
            finally
            {
                CredFree(ptr);
            }
        }

        [SupportedOSPlatform("windows")]
        public static void CredDelete(string target) => CredDeleteW(target, CredTypeGeneric, 0);
    }
}

/// <summary>Env overrides persistent store (Credential Manager on Windows, file on Mac/Linux).</summary>
public sealed class CompositeSecretStore : ISecretStore
{
    private readonly EnvSecretStore _env = new();
    private readonly ISecretStore _persistent;

    public CompositeSecretStore(ISecretStore? persistent = null)
    {
        _persistent = persistent ?? (WindowsCredentialStore.IsSupported
            ? new WindowsCredentialStore()
            : new FileSecretStore());
    }

    public bool IsPersistent => _persistent.IsPersistent;

    public static CompositeSecretStore Default { get; } = new();

    public string? GetSecret(string account)
    {
        var fromEnv = _env.GetSecret(account);
        if (!string.IsNullOrEmpty(fromEnv))
            return fromEnv;
        return _persistent.GetSecret(account);
    }

    public void SetSecret(string account, string value) => _persistent.SetSecret(account, value);

    public void DeleteSecret(string account)
    {
        _persistent.DeleteSecret(account);
        _env.DeleteSecret(account);
    }
}
