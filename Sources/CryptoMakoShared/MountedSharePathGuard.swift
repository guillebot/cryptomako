import Foundation

/// Ensure a folder-picker result stays inside the mounted SMB volume.
public enum MountedSharePathGuard: Sendable {
    /// True when `candidatePath` is the volume root or a descendant after
    /// standardizing. When `resolveSymlinks` is true (picker path), a symlink that
    /// escapes the volume is rejected.
    public static func isInsideMountedVolume(
        candidatePath: String,
        volumeRootPath: String,
        resolveSymlinks: Bool = true
    ) -> Bool {
        let root = normalize(volumeRootPath, resolveSymlinks: resolveSymlinks)
        let path = normalize(candidatePath, resolveSymlinks: resolveSymlinks)
        if path.caseInsensitiveCompare(root) == .orderedSame {
            return true
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.lowercased().hasPrefix(prefix.lowercased())
    }

    private static func normalize(_ path: String, resolveSymlinks: Bool) -> String {
        var url = URL(fileURLWithPath: path)
        if resolveSymlinks {
            url = url.resolvingSymlinksInPath()
        }
        var p = url.standardizedFileURL.path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}
