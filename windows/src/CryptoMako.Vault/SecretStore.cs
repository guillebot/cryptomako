using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace CryptoMako.Vault;

/// <summary>
/// Secret lookup/store. Never write secrets to settings.json.
/// Production Windows: Credential Manager; elsewhere / CI: environment variables.
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

/// <summary>Env overrides Credential Manager so CI/`CRYPTOMAKO_*` keep working.</summary>
public sealed class CompositeSecretStore : ISecretStore
{
    private readonly EnvSecretStore _env = new();
    private readonly WindowsCredentialStore _windows = new();

    public bool IsPersistent => _windows.IsPersistent;

    public static CompositeSecretStore Default { get; } = new();

    public string? GetSecret(string account)
    {
        var fromEnv = _env.GetSecret(account);
        if (!string.IsNullOrEmpty(fromEnv))
            return fromEnv;
        if (WindowsCredentialStore.IsSupported)
            return _windows.GetSecret(account);
        return null;
    }

    public void SetSecret(string account, string value)
    {
        if (WindowsCredentialStore.IsSupported)
            _windows.SetSecret(account, value);
        else
            _env.SetSecret(account, value);
    }

    public void DeleteSecret(string account)
    {
        if (WindowsCredentialStore.IsSupported)
            _windows.DeleteSecret(account);
        _env.DeleteSecret(account);
    }
}
