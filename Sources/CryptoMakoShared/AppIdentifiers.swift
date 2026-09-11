import Foundation

public enum AppIdentifiers {
    public static let hostBundleID = "net.gschimmel.cryptomako"
    public static let extensionBundleID = "net.gschimmel.cryptomako.FileProvider"
    /// Needs the team ID in front once one exists: macOS App Groups are
    /// team-prefixed, and `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// just returns nil for the bare form rather than reporting an error. The
    /// entitlements get the prefix from `$(AppIdentifierPrefix)`; this cannot.
    public static let appGroup = "group.net.gschimmel.cryptomako"

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
