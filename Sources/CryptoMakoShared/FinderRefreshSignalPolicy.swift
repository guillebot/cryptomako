import Foundation

/// Counts the File Provider refresh watcher compares between polls.
public struct FinderRefreshSignalCounts: Equatable, Sendable {
    public var filesUploaded: Int
    public var filesDeleted: Int

    public init(filesUploaded: Int, filesDeleted: Int) {
        self.filesUploaded = filesUploaded
        self.filesDeleted = filesDeleted
    }
}

/// Decides when Backup Sync may wake the Finder File Provider extension.
///
/// Unconditional 6s signaling keeps runningboardd churning the appex for hours
/// of steady upload. Signal only when upload/delete counts advance, and at most
/// once per `minimumInterval` during a run. Completion always forces a signal.
public enum FinderRefreshSignalPolicy: Sendable {
    /// Ceiling during steady upload (~30s).
    public static let minimumInterval: TimeInterval = 30

    /// - Parameters:
    ///   - lastSignaled: Counts at the last successful signal in this run (zeros before any).
    ///   - current: Live engine counts.
    ///   - elapsedSinceLastSignal: `nil` when nothing has been signaled yet this run.
    ///   - force: Completion (or other must-refresh) path — always signals.
    public static func shouldSignal(
        lastSignaled: FinderRefreshSignalCounts,
        current: FinderRefreshSignalCounts,
        elapsedSinceLastSignal: TimeInterval?,
        force: Bool,
        minimumInterval: TimeInterval = minimumInterval
    ) -> Bool {
        if force { return true }
        let changed =
            current.filesUploaded != lastSignaled.filesUploaded
            || current.filesDeleted != lastSignaled.filesDeleted
        guard changed else { return false }
        guard let elapsed = elapsedSinceLastSignal else { return true }
        return elapsed >= minimumInterval
    }
}
