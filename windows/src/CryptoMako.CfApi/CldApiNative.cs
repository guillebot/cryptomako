using System.Runtime.InteropServices;

namespace CryptoMako.CfApi;

/// <summary>P/Invoke surface for cldapi.dll (Windows Cloud Files).</summary>
internal static class CldApiNative
{
    public const uint CF_REGISTER_FLAG_NONE = 0;
    public const uint CF_REGISTER_FLAG_UPDATE = 1;
    public const uint CF_REGISTER_FLAG_DISABLE_ON_DEMAND_POPULATION_ON_ROOT = 2;
    public const uint CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT = 4;

    public const uint CF_CONNECT_FLAG_NONE = 0;
    public const uint CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO = 2;
    public const uint CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH = 4;
    public const uint CF_CONNECT_FLAG_BLOCKING = 8;

    public const ushort CF_HYDRATION_POLICY_PARTIAL = 0;
    public const ushort CF_HYDRATION_POLICY_PROGRESSIVE = 1;
    public const ushort CF_HYDRATION_POLICY_FULL = 2;
    public const ushort CF_HYDRATION_POLICY_ALWAYS_FULL = 3;
    public const ushort CF_HYDRATION_POLICY_MODIFIER_NONE = 0;

    public const ushort CF_POPULATION_POLICY_PARTIAL = 0;
    public const ushort CF_POPULATION_POLICY_FULL = 2;
    public const ushort CF_POPULATION_POLICY_ALWAYS_FULL = 3;
    public const ushort CF_POPULATION_POLICY_MODIFIER_NONE = 0;

    public const uint CF_INSYNC_POLICY_NONE = 0;
    public const uint CF_HARDLINK_POLICY_NONE = 0;
    public const uint CF_PLACEHOLDER_MANAGEMENT_POLICY_DEFAULT = 0;

    public const uint CF_CALLBACK_TYPE_NONE = 0;
    public const uint CF_CALLBACK_TYPE_FETCH_DATA = 1;
    public const uint CF_CALLBACK_TYPE_VALIDATE_DATA = 2;
    public const uint CF_CALLBACK_TYPE_CANCEL_FETCH_DATA = 3;
    public const uint CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS = 4;
    public const uint CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS = 5;
    public const uint CF_CALLBACK_TYPE_NOTIFY_FILE_OPEN_COMPLETION = 6;
    public const uint CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION = 7;
    public const uint CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE = 8;
    public const uint CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE_COMPLETION = 9;
    public const uint CF_CALLBACK_TYPE_NOTIFY_DELETE = 10;
    public const uint CF_CALLBACK_TYPE_NOTIFY_DELETE_COMPLETION = 11;
    public const uint CF_CALLBACK_TYPE_NOTIFY_RENAME = 12;
    public const uint CF_CALLBACK_TYPE_NOTIFY_RENAME_COMPLETION = 13;

    [StructLayout(LayoutKind.Sequential)]
    public struct CF_HYDRATION_POLICY
    {
        public ushort Primary;
        public ushort Modifier;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CF_POPULATION_POLICY
    {
        public ushort Primary;
        public ushort Modifier;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CF_SYNC_POLICIES
    {
        public uint StructSize;
        public CF_HYDRATION_POLICY Hydration;
        public CF_POPULATION_POLICY Population;
        public uint InSync;
        public uint HardLink;
        public uint PlaceholderManagement;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CF_SYNC_REGISTRATION
    {
        public uint StructSize;
        public IntPtr ProviderName;
        public IntPtr ProviderVersion;
        public IntPtr SyncRootIdentity;
        public uint SyncRootIdentityLength;
        public IntPtr FileIdentity;
        public uint FileIdentityLength;
        public Guid ProviderId;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct CF_CALLBACK_REGISTRATION
    {
        public uint Type;
        public IntPtr Callback; // CF_CALLBACK*
    }

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int CfRegisterSyncRoot(
        string SyncRootPath,
        in CF_SYNC_REGISTRATION Registration,
        in CF_SYNC_POLICIES Policies,
        uint RegisterFlags);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int CfUnregisterSyncRoot(string SyncRootPath);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int CfConnectSyncRoot(
        string SyncRootPath,
        IntPtr CallbackTable,
        IntPtr CallbackContext,
        uint ConnectFlags,
        out long ConnectionKey);

    [DllImport("cldapi.dll", ExactSpelling = true)]
    public static extern int CfDisconnectSyncRoot(long ConnectionKey);

    [DllImport("cldapi.dll", ExactSpelling = true)]
    public static extern int CfGetPlatformInfo(out CF_PLATFORM_INFO PlatformInfo);

    [StructLayout(LayoutKind.Sequential)]
    public struct CF_PLATFORM_INFO
    {
        public uint BuildNumber;
        public uint RevisionNumber;
        public uint IntegrationNumber;
    }

    public static void ThrowOnFailed(int hr, string api)
    {
        if (hr >= 0) return;
        var ex = Marshal.GetExceptionForHR(hr) ?? new InvalidOperationException($"{api} failed HRESULT=0x{hr:X8}");
        throw new InvalidOperationException($"{api} failed HRESULT=0x{hr:X8}: {ex.Message}", ex);
    }
}

