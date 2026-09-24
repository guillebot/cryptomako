import Foundation

/// Cross-process transfer stats (host app ↔ File Provider) via the App Group.
///
/// Counts **remote** ObjectStore commits only (S3 put/get/delete). Local CloudStorage
/// materialization that never reached MinIO must not inflate these numbers.
public struct TransferSnapshot: Codable, Equatable, Sendable {
    public var inFlight: Int
    public var completedPuts: Int
    public var failedPuts: Int
    public var completedDeletes: Int
    public var bytesUploaded: Int64
    public var bytesDownloaded: Int64
    public var currentName: String?
    public var lastError: String?
    public var lastRemoteCommitAt: Date?
    /// Exponentially-smoothed upload rate from recent puts (bytes/sec).
    public var uploadBytesPerSecond: Double
    public var updatedAt: Date

    public static let empty = TransferSnapshot(
        inFlight: 0,
        completedPuts: 0,
        failedPuts: 0,
        completedDeletes: 0,
        bytesUploaded: 0,
        bytesDownloaded: 0,
        currentName: nil,
        lastError: nil,
        lastRemoteCommitAt: nil,
        uploadBytesPerSecond: 0,
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public var tooltipLines: [String] {
        var lines = ["CryptoMako — remote transfers"]
        if inFlight > 0 {
            let name = currentName.map { " \($0)" } ?? ""
            lines.append("Uploading:\(name) (\(inFlight) in flight)")
        } else {
            lines.append("Idle (no remote put in flight)")
        }
        lines.append("Uploaded: \(completedPuts) files, \(Self.formatBytes(bytesUploaded))")
        if completedDeletes > 0 {
            lines.append("Deleted: \(completedDeletes) remote objects")
        }
        if failedPuts > 0 {
            lines.append("Failed puts: \(failedPuts)")
        }
        let live = liveUploadBytesPerSecond()
        if live > 0 {
            lines.append("Bandwidth: \(Self.formatRate(live))")
        }
        if let lastError, !lastError.isEmpty {
            lines.append("Last error: \(lastError)")
        }
        return lines
    }

    public var tooltip: String { tooltipLines.joined(separator: "\n") }

    /// Human size for Sync / transfer UI (decimal SI units: 1000-based KB/MB/GB/TB).
    /// At or above 1000 GB (1e12 bytes) shows TB with 2 decimal places so large
    /// photo libraries read as e.g. `1.25 TB` instead of `1250.00 GB`.
    public static func formatBytes(_ n: Int64) -> String {
        let abs = Double(Swift.abs(n))
        if abs < 1000 { return "\(n) B" }
        if abs < 1_000_000 { return String(format: "%.1f KB", abs / 1_000) }
        if abs < 1_000_000_000 { return String(format: "%.1f MB", abs / 1_000_000) }
        // Keep GB below 1000 GB; switch to TB at ≥ 1000 * 10^9 bytes.
        if abs < 1_000_000_000_000 { return String(format: "%.2f GB", abs / 1_000_000_000) }
        return String(format: "%.2f TB", abs / 1_000_000_000_000)
    }

    /// Human rate for the strip / tooltip (avoids "44 B/s" looking like a frozen bug when idle).
    public static func formatRate(_ bytesPerSecond: Double) -> String {
        let r = max(0, bytesPerSecond)
        if r < 1 { return "0 B/s" }
        if r < 1000 { return String(format: "%.0f B/s", r) }
        if r < 1_000_000 { return String(format: "%.1f KB/s", r / 1_000) }
        if r < 1_000_000_000 { return String(format: "%.1f MB/s", r / 1_000_000) }
        return String(format: "%.2f GB/s", r / 1_000_000_000)
    }

    /// Display rate for the strip / menu.
    ///
    /// - While puts are in flight: keep the last EMA. Backup Sync large files are
    ///   single-slot and often take >>2.5s between `endPutSuccess` commits; blanking
    ///   the meter made Sync look "all off" even though MinIO was receiving data.
    /// - When idle: hide stale EMA after ~2.5s (avoids a frozen trickle after drain).
    /// Stuck `inFlight` is soft-healed in `TransferMetrics.load` after ~90s.
    public func liveUploadBytesPerSecond(now: Date = Date()) -> Double {
        guard uploadBytesPerSecond > 0 else { return 0 }
        if inFlight > 0 {
            return uploadBytesPerSecond
        }
        if let last = lastRemoteCommitAt, now.timeIntervalSince(last) <= 2.5 {
            return uploadBytesPerSecond
        }
        return 0
    }
}


public enum TransferMetrics {
    public static let didChangeNotification = Notification.Name("net.gschimmel.cryptomako.transferMetrics")

    private static let lock = NSLock()
    /// Wall-clock window for bandwidth under parallel puts (start times are not 1:1).
    private static var rateWindowStartedAt: Date?
    private static var rateWindowBytes: Int64 = 0
    /// Hot-path cache: avoid read+atomic-write JSON on every begin/end put (was
    /// serializing Sync under a global lock and stomping the cooperative pool).
    private static var memory: TransferSnapshot?
    private static var persistPending = false
    private static var notifyPending = false
    private static let persistQueue = DispatchQueue(label: "net.gschimmel.cryptomako.transfer-metrics.persist")

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("transfer-metrics.json")
    }

    public static func load() -> TransferSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snap = memory ?? loadUnlocked()
        memory = snap
        // Soft-heal a crashed mid-put: inFlight stuck forever with a frozen EMA.
        if snap.inFlight > 0, Date().timeIntervalSince(snap.updatedAt) > 90 {
            snap.inFlight = 0
            snap.currentName = nil
            snap.uploadBytesPerSecond = 0
            memory = snap
            saveUnlocked(snap)
            rateWindowStartedAt = nil
            rateWindowBytes = 0
        }
        return snap
    }

    public static func reset() {
        lock.lock()
        memory = TransferSnapshot.empty
        rateWindowStartedAt = nil
        rateWindowBytes = 0
        saveUnlocked(TransferSnapshot.empty)
        lock.unlock()
        DistributedNotificationCenter.default().post(name: didChangeNotification, object: nil)
    }

    /// Poll until no remote puts are in flight (or timeout). Used before disconnect
    /// so Lock/Unmount drain MinIO uploads instead of abandoning them mid-flight.
    @discardableResult
    public static func waitUntilIdle(
        timeoutSeconds: TimeInterval = 600,
        quietSeconds: TimeInterval = 0.75,
        onProgress: ((TransferSnapshot) -> Void)? = nil
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let snap = load()
            onProgress?(snap)
            if snap.inFlight == 0 {
                try? await Task.sleep(nanoseconds: UInt64(quietSeconds * 1_000_000_000))
                if load().inFlight == 0 { return true }
                continue
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return load().inFlight == 0
    }

    public static func beginPut(name: String) {
        mutate { snap in
            var s = snap
            s.inFlight += 1
            s.currentName = name
            s.lastError = nil
            s.updatedAt = Date()
            return s
        }
        lock.lock()
        if rateWindowStartedAt == nil {
            rateWindowStartedAt = Date()
            rateWindowBytes = 0
        }
        lock.unlock()
    }

    public static func endPutSuccess(bytes: Int64) {
        var rate = 0.0
        lock.lock()
        rateWindowBytes += max(0, bytes)
        if let started = rateWindowStartedAt {
            let dt = Date().timeIntervalSince(started)
            // Refresh EMA every ~0.75s of wall time so parallel puts share one window.
            if dt >= 0.35, rateWindowBytes > 0 {
                rate = Double(rateWindowBytes) / max(dt, 0.001)
                rateWindowStartedAt = Date()
                rateWindowBytes = 0
            }
        }
        lock.unlock()

        mutate { snap in
            var s = snap
            s.inFlight = max(0, s.inFlight - 1)
            s.completedPuts += 1
            s.bytesUploaded += max(0, bytes)
            s.lastRemoteCommitAt = Date()
            s.updatedAt = Date()
            if s.inFlight == 0 { s.currentName = nil }
            if rate > 0 {
                s.uploadBytesPerSecond = s.uploadBytesPerSecond == 0
                    ? rate
                    : (s.uploadBytesPerSecond * 0.7 + rate * 0.3)
            }
            return s
        }
    }

    public static func endPutFailure(_ message: String) {
        mutate { snap in
            var s = snap
            s.inFlight = max(0, s.inFlight - 1)
            s.failedPuts += 1
            s.lastError = String(message.prefix(160))
            s.updatedAt = Date()
            if s.inFlight == 0 { s.currentName = nil }
            return s
        }
    }

    public static func recordDeleteSuccess() {
        mutate { snap in
            var s = snap
            s.completedDeletes += 1
            s.lastRemoteCommitAt = Date()
            s.updatedAt = Date()
            return s
        }
    }

    public static func recordDownload(bytes: Int64) {
        mutate { snap in
            var s = snap
            s.bytesDownloaded += max(0, bytes)
            s.updatedAt = Date()
            return s
        }
    }

    private static func mutate(_ body: (TransferSnapshot) -> TransferSnapshot) {
        lock.lock()
        let base = memory ?? loadUnlocked()
        let prevInFlight = base.inFlight
        let next = body(base)
        memory = next
        // Persist immediately when inFlight crosses 0↔N so Backup Sync's live
        // strip / transfer-metrics.json is not stuck at inFlight=0 for 200ms+
        // while puts are already encrypting/uploading.
        // Urgent persist only on idle↔busy so dozens of parallel puts do not
        // thrash the App Group JSON every begin/end (was competing with PUT I/O).
        let inFlightEdge = (prevInFlight == 0) != (next.inFlight == 0)
        let shouldSchedulePersist = !persistPending
        if shouldSchedulePersist { persistPending = true }
        let shouldScheduleNotify = !notifyPending
        if shouldScheduleNotify { notifyPending = true }
        lock.unlock()
        if shouldSchedulePersist {
            let delay: TimeInterval = inFlightEdge ? 0.02 : 0.2
            persistQueue.asyncAfter(deadline: .now() + delay) {
                lock.lock()
                let snap = memory ?? TransferSnapshot.empty
                persistPending = false
                lock.unlock()
                lock.lock()
                saveUnlocked(snap)
                lock.unlock()
            }
        }
        if shouldScheduleNotify {
            let delay: TimeInterval = inFlightEdge ? 0.02 : 0.15
            persistQueue.asyncAfter(deadline: .now() + delay) {
                lock.lock()
                notifyPending = false
                lock.unlock()
                DistributedNotificationCenter.default().post(name: didChangeNotification, object: nil)
            }
        }
    }

    private static func loadUnlocked() -> TransferSnapshot {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(TransferSnapshot.self, from: data)
        else {
            return TransferSnapshot.empty
        }
        return snap
    }

    private static func saveUnlocked(_ snap: TransferSnapshot) {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snap)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort; never fail vault I/O because metrics could not persist.
        }
    }
}
