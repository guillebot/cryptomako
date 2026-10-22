import Foundation

/// Local-only decision for one Backup Sync walk entry.
///
/// Skip vs enqueue must use size + mtime from the local index only. Vault LIST /
/// `dir.c9r` lookups belong in put workers (or Sync prune), never on the
/// enumeration hot path — a cold index on a multi-million-file SMB tree would
/// otherwise serialize a remote round-trip per directory (or worse, per file).
public enum BackupWalkFileAction: Equatable, Sendable {
    /// Fingerprint matches the local index — do not upload, do not touch the vault.
    case skipUnchanged
    /// Missing or stale local fingerprint — enqueue a put (workers resolve dirs).
    case enqueueUpload
}

public enum BackupWalkSkipPolicy: Sendable {
    /// Pure function: no I/O, no vault, no reachability probe.
    public static func action(
        indexed: BackupFileFingerprint?,
        size: Int64,
        contentModification: Date
    ) -> BackupWalkFileAction {
        if indexed?.matches(size: size, contentModification: contentModification) == true {
            return .skipUnchanged
        }
        return .enqueueUpload
    }
}
