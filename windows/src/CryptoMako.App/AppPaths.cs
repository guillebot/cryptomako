namespace CryptoMako.App;

public static class AppPaths
{
    public static string ConfigDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CryptoMako");

    public static string SettingsPath => Path.Combine(ConfigDir, "settings.json");
    public static string PreferencesPath => Path.Combine(ConfigDir, "app-preferences.json");
    public static string SyncStatePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CryptoMako", "backup-sync-state.json");
}
