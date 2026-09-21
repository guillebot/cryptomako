import Foundation

public enum AppIdentifiers {
    public static let hostBundleID = "net.gschimmel.cryptomako"
    public static let extensionBundleID = "net.gschimmel.cryptomako.FileProvider"
    /// Team-prefixed App Group (macOS). Entitlements still use $(AppIdentifierPrefix);
    /// this Swift constant must be the literal form or containerURL returns nil.
    public static let appGroup = "H4K6YW7MQM.group.net.gschimmel.cryptomako"

    /// Keychain service. The access group is prefixed with the team ID at runtime
    /// by the entitlement, so it is not spelled out here.
    public static let keychainService = "net.gschimmel.cryptomako"
    public static let keychainAccessGroup = "group.net.gschimmel.cryptomako"

    public static let secretKeyAccount = "s3-secret-key"
    public static let passwordAccount = "vault-password"

    /// Domain identifier is derived from the vault JWT `jti` so two vaults never collide.
    public static func domainIdentifier(jti: String) -> String {
        "cryptomako.\(jti)"
    }
}
