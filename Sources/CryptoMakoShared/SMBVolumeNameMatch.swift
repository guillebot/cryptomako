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

    /// Fail-closed identity check for a mounted SMB volume.
    /// `mountedFrom` is the `statfs.f_mntfromname` value (for example `//host/share`).
    public static func mountMatches(
        volumeLeaf: String,
        isLocal: Bool,
        mountedFrom: String,
        expectedSMBURL: String
    ) -> Bool {
        guard !isLocal,
              let expected = hostAndShare(fromSMBURL: expectedSMBURL),
              let actual = hostAndShare(fromMountedFrom: mountedFrom),
              Self.volumeLeaf(volumeLeaf, matchesShare: expected.share)
        else {
            return false
        }
        return actual.host.caseInsensitiveCompare(expected.host) == .orderedSame
            && actual.share.caseInsensitiveCompare(expected.share) == .orderedSame
    }

    private static func hostAndShare(fromSMBURL value: String) -> (host: String, share: String)? {
        guard let url = URL(string: value),
              url.scheme?.caseInsensitiveCompare("smb") == .orderedSame,
              let host = url.host,
              let share = url.path.split(separator: "/").first.map(String.init),
              !host.isEmpty,
              !share.isEmpty
        else {
            return nil
        }
        return (host, share.removingPercentEncoding ?? share)
    }

    private static func hostAndShare(fromMountedFrom value: String) -> (host: String, share: String)? {
        guard value.hasPrefix("//") else { return nil }
        let parts = value.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let authority = String(parts[0])
        let host = authority.split(separator: "@").last.map(String.init) ?? ""
        let share = String(parts[1])
        guard !host.isEmpty, !share.isEmpty else { return nil }
        return (host, share.removingPercentEncoding ?? share)
    }
}
