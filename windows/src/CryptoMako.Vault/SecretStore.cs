namespace CryptoMako.Vault;

/// <summary>
/// Secret lookup stub. Production will use Windows Credential Manager;
/// today: environment variables only. Never write secrets to settings.json.
/// </summary>
public interface ISecretStore
{
    string? GetSecret(string account);
}

public sealed class EnvSecretStore : ISecretStore
{
    public const string PasswordAccount = "CRYPTOMAKO_PASSWORD";
    public const string SecretKeyAccount = "CRYPTOMAKO_SECRET_KEY";
    public const string ProxyPasswordAccount = "CRYPTOMAKO_PROXY_PASSWORD";

    public string? GetSecret(string account)
    {
        var value = Environment.GetEnvironmentVariable(account);
        return string.IsNullOrEmpty(value) ? null : value;
    }
}
