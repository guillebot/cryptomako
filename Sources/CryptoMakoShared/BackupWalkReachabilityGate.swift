import Foundation

/// Throttles mid-walk source reachability probes during Backup Sync enumeration.
///
/// `SMBBackupMount.assertSourceReachable` touches volume metadata (`fileExists` +
/// `resourceValues` for volume name/UUID). On SMB that is a network round-trip; calling
/// it every N enumerated entries turns a multi-million-file walk into an hour-long
/// probe storm. This gate keeps mid-walk checks on a wall-clock interval instead.
///
/// Mandatory probes (start of walk, end of enumeration, before Sync prune) are always
/// issued by the caller — this type only answers "should we probe again *now*?".
public struct BackupWalkReachabilityGate: Sendable {
    /// Default mid-walk spacing. Short enough to notice a dropped share; long enough
    /// that a large SMB tree is not dominated by volume-metadata RPCs.
    public static let defaultMinInterval: TimeInterval = 3.0

    public let minInterval: TimeInterval
    private var lastProbeAt: Date?

    public init(minInterval: TimeInterval = Self.defaultMinInterval) {
        self.minInterval = max(0, minInterval)
    }

    /// Record that a probe just ran (e.g. the mandatory start-of-walk check) so the
    /// first mid-walk decision respects `minInterval`.
    public mutating func markProbed(now: Date = Date()) {
        lastProbeAt = now
    }

    /// `true` when a mid-walk probe should run. Updates the last-probe timestamp when
    /// returning `true`. Inject `now` in tests.
    public mutating func shouldProbe(now: Date = Date()) -> Bool {
        if let last = lastProbeAt, now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastProbeAt = now
        return true
    }
}
