import Foundation

/// Pure helpers for `smb://` Backup Sync sources (no NetFS / no Keychain).
public enum SMBSourceURL {
    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case notSMB
        case missingHost
        case missingShare

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "SMB URL is empty."
            case .notSMB:
                return "SMB URL must start with smb:// (example: smb://server/share or smb://server/share/path)."
            case .missingHost:
                return "SMB URL is missing a server host."
            case .missingShare:
                return "SMB URL must include a share name (smb://server/share)."
            }
        }
    }

    /// Normalize user input into a canonical `smb://host/share[/path]` string (no credentials in URL).
    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        var working = trimmed
        if working.lowercased().hasPrefix("\\\\") || working.hasPrefix("//") {
            // UNC → smb://host/share/…
            var unc = working
            while unc.hasPrefix("\\") || unc.hasPrefix("/") {
                unc.removeFirst()
            }
            let parts = unc.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
            guard parts.count >= 2 else { throw ParseError.missingShare }
            working = "smb://" + parts.joined(separator: "/")
        }

        guard let url = URL(string: working), let scheme = url.scheme?.lowercased(), scheme == "smb" else {
            throw ParseError.notSMB
        }
        guard let host = url.host, !host.isEmpty else {
            throw ParseError.missingHost
        }

        let pathParts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard let share = pathParts.first, !share.isEmpty else {
            throw ParseError.missingShare
        }
        let remainder = pathParts.dropFirst()
        var normalized = "smb://\(host)"
        if let port = url.port {
            normalized += ":\(port)"
        }
        normalized += "/\(share)"
        if !remainder.isEmpty {
            normalized += "/" + remainder.joined(separator: "/")
        }
        return normalized
    }

    public static func suggestedVaultFolderName(smbURL: String?, path: String) -> String {
        if let smbURL, let share = (try? normalize(smbURL)).flatMap({ shareName(from: $0) }), !share.isEmpty {
            return share
        }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        return leaf.isEmpty ? "SMB" : leaf
    }

    public static func shareName(from normalizedSMBURL: String) -> String? {
        guard let url = URL(string: normalizedSMBURL) else { return nil }
        return url.path.split(separator: "/").map(String.init).first
    }

    /// Host + share for short UI badges.
    public static func shortLabel(from normalizedSMBURL: String) -> String {
        guard let url = URL(string: normalizedSMBURL), let host = url.host else {
            return normalizedSMBURL
        }
        let share = shareName(from: normalizedSMBURL) ?? ""
        return share.isEmpty ? host : "\(host)/\(share)"
    }
}
