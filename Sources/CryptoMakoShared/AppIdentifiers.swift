import Foundation

public enum AppIdentifiers {
    public static let hostBundleID = "net.gschimmel.cryptomako"
    public static let extensionBundleID = "net.gschimmel.cryptomako.FileProvider"
    /// Team-prefixed App Group (macOS). Entitlements still use $(AppIdentifierPrefix);
    /// this Swift constant must be the literal form or containerURL returns nil.
    public static let appGroup = "H4K6YW7MQM.group.net.gschimmel.cryptomako"

    /// Keychain service name (shown in Keychain Access).
    public static let keychainService = "net.gschimmel.cryptomako"
    /// Must match `keychain-access-groups` / App Group with Team ID prefix.
    /// Bare `group.…` without the team ID falls back to classic ACL Keychain
    /// items that re-prompt on every Debug rebuild.
    public static let keychainAccessGroup = "H4K6YW7MQM.group.net.gschimmel.cryptomako"

    public static let secretKeyAccount = "s3-secret-key"
    public static let passwordAccount = "vault-password"
    public static let proxyPasswordAccount = "http-proxy-password"

    /// Domain identifier is derived from the vault JWT `jti` so two vaults never collide.
    public static func domainIdentifier(jti: String) -> String {
        "cryptomako.\(jti)"
    }
}
