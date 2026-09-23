namespace CryptoMako.App;

public static class AppPaths
{
    public static string ConfigDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CryptoMako");

    public static string SettingsPath => Path.Combine(ConfigDir, "settings.json");
    public static string PreferencesPath => Path.Combine(ConfigDir, "app-preferences.json");
    /// <summary>Windows-local backup sources list (not settings.json).</summary>
    public static string BackupSourcesPath => Path.Combine(ConfigDir, "backup-sources.json");
    public static string SyncStatePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CryptoMako", "backup-sync-state.json");

    /// <summary>Default soft CfAPI sync root under LocalAppData (Explorer viewer).</summary>
    public static string SyncRootPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CryptoMako", "SyncRoot");
}
