import Foundation

/// Stable File Provider item id, independent of `NSFileProviderItemIdentifier`
/// so it can be unit-tested without linking FileProvider.
///
/// - Directory: `d:<dirId>` (empty dirId is the vault root)
/// - File: `f:<parentDirId>/<cipherName>`
public enum ItemIdentifier: Equatable, Sendable {
    case root
    case directory(dirId: String)
    case file(parentDirId: String, cipherName: String)

    public init?(rawValue: String) {
        if rawValue.isEmpty || rawValue == "root" {
            self = .root
            return
        }
        if rawValue.hasPrefix("d:") {
            let dirId = String(rawValue.dropFirst(2))
            self = dirId.isEmpty ? .root : .directory(dirId: dirId)
            return
        }
        if rawValue.hasPrefix("f:") {
            let rest = String(rawValue.dropFirst(2))
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            self = .file(
                parentDirId: String(rest[rest.startIndex..<slash]),
                cipherName: String(rest[rest.index(after: slash)...])
            )
            return
        }
        return nil
    }

    public var rawValue: String {
        switch self {
        case .root:
            return "d:"
        case .directory(let dirId):
            return "d:\(dirId)"
        case .file(let parentDirId, let cipherName):
            return "f:\(parentDirId)/\(cipherName)"
        }
    }

    public static func of(_ node: VaultNode) -> ItemIdentifier {
        switch node.kind {
        case .directory:
            let dirId = node.dirId ?? ""
            return dirId.isEmpty ? .root : .directory(dirId: dirId)
        case .file, .symlink:
            return .file(parentDirId: node.parentDirId, cipherName: node.cipherName)
        }
    }
}
