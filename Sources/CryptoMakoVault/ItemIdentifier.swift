import Foundation

/// Stable File Provider item id, independent of `NSFileProviderItemIdentifier`
/// so it can be unit-tested without linking FileProvider.
///
/// - Directory: `d:<parentDirId>/<dirId>` (empty parentDirId = child of vault root).
///   Legacy `d:<dirId>` (no slash) is still accepted and resolved via a root walk.
/// - File: `f:<parentDirId>/<cipherName>`
public enum ItemIdentifier: Equatable, Sendable {
    case root
    /// `parentDirId` is nil only for legacy identifiers that omitted the parent.
    case directory(dirId: String, parentDirId: String?)
    case file(parentDirId: String, cipherName: String)

    public init?(rawValue: String) {
        if rawValue.isEmpty || rawValue == "root" {
            self = .root
            return
        }
        if rawValue.hasPrefix("d:") {
            let rest = String(rawValue.dropFirst(2))
            if rest.isEmpty {
                self = .root
                return
            }
            if let slash = rest.firstIndex(of: "/") {
                let parent = String(rest[rest.startIndex..<slash])
                let dirId = String(rest[rest.index(after: slash)...])
                guard !dirId.isEmpty else { return nil }
                self = .directory(dirId: dirId, parentDirId: parent)
            } else {
                // Legacy: parent unknown — DirectoryIndex walks from root.
                self = .directory(dirId: rest, parentDirId: nil)
            }
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
        case .directory(let dirId, let parentDirId):
            if let parentDirId {
                // Parent embedded so delete/trash never depends on the listing cache.
                return "d:\(parentDirId)/\(dirId)"
            }
            // Legacy / parent-ref form.
            return "d:\(dirId)"
        case .file(let parentDirId, let cipherName):
            return "f:\(parentDirId)/\(cipherName)"
        }
    }

    public static func of(_ node: VaultNode) -> ItemIdentifier {
        switch node.kind {
        case .directory:
            let dirId = node.dirId ?? ""
            return dirId.isEmpty
                ? .root
                : .directory(dirId: dirId, parentDirId: node.parentDirId)
        case .file, .symlink:
            return .file(parentDirId: node.parentDirId, cipherName: node.cipherName)
        }
    }
}
