import Foundation

/// Match `/Volumes/<leaf>` names to an SMB share without arbitrary prefixes.
///
/// macOS may mount the same share as `photos`, then `photos-1`, `photos-2` when
/// the base name is taken. A suffix that is not only digits (e.g. `photos-backup`)
/// is a different volume and must not match share `photos`.
public enum SMBVolumeNameMatch: Sendable {
    /// Case-insensitive. Exact share name, or `share-<digits>` duplicate mounts only.
    public static func volumeLeaf(_ leaf: String, matchesShare share: String) -> Bool {
        let leafFolded = leaf.lowercased()
        let shareFolded = share.lowercased()
        if leafFolded == shareFolded {
            return true
        }
        let marker = shareFolded + "-"
        guard leafFolded.hasPrefix(marker) else {
            return false
        }
        let suffix = leafFolded.dropFirst(marker.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}
