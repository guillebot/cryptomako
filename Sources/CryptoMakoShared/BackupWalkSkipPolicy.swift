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

/// One enumerator-thread decision after local size and mtime are already in hand.
///
/// `probe`, `listVault`, and `saveIndex` are the side effects that made SMB walks
/// wait on the network or rewrite the whole fingerprint file. They stay false:
/// a matching fingerprint is skip-only, and a miss only enqueues a put.
public struct BackupWalkEntryStep: Equatable, Sendable {
    public var action: BackupWalkFileAction
    public var probe: Bool
    public var listVault: Bool
    public var saveIndex: Bool

    public init(action: BackupWalkFileAction, probe: Bool, listVault: Bool, saveIndex: Bool) {
        self.action = action
        self.probe = probe
        self.listVault = listVault
        self.saveIndex = saveIndex
    }
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

    /// Enumerator hot path. Never probes, lists the vault, or saves the index.
    public static func step(
        indexed: BackupFileFingerprint?,
        size: Int64,
        contentModification: Date
    ) -> BackupWalkEntryStep {
        BackupWalkEntryStep(
            action: action(
                indexed: indexed,
                size: size,
                contentModification: contentModification
            ),
            probe: false,
            listVault: false,
            saveIndex: false
        )
    }
}
