import Foundation

/// Mode-dependent directory walk options for Backup Sync's local scan.
///
/// Sync must see hidden files that still exist on disk so the prune allow-set
/// includes them (1.0.9 H1: never delete vault ciphertext for a present hidden
/// path). Backup has no prune / allow-set, so enumerating `.DS_Store` / `._*`
/// over SMB is wasted work — skip them at the enumerator.
public enum BackupScanEnumeratorPolicy: Sendable {
    /// Options passed to `FileManager.enumerator`. Always skips package
    /// descendants. Adds `.skipsHiddenFiles` only in Backup mode.
    public static func directoryEnumerationOptions(
        isSyncMode: Bool
    ) -> FileManager.DirectoryEnumerationOptions {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !isSyncMode {
            options.insert(.skipsHiddenFiles)
        }
        return options
    }

    /// True when the scan enumerator should omit hidden entries entirely.
    /// Sync must return false (H1). Backup returns true (performance).
    public static func skipsHiddenFiles(isSyncMode: Bool) -> Bool {
        !isSyncMode
    }
}
