import Foundation

public struct TransferFailure: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case unresolved
        case resolved
    }

    public var id: UUID
    public var runID: UUID?
    public var sourceID: String?
    public var path: String
    public var timestamp: Date
    public var category: String
    public var operation: String
    public var attempts: Int
    public var retryable: Bool
    public var status: Status
    public var resolvedAt: Date?
    public var message: String

    public init(
        id: UUID = UUID(),
        runID: UUID?,
        sourceID: String?,
        path: String,
        timestamp: Date = Date(),
        category: String,
        operation: String,
        attempts: Int,
        retryable: Bool,
        status: Status = .unresolved,
        resolvedAt: Date? = nil,
        message: String
    ) {
        self.id = id
        self.runID = runID
        self.sourceID = sourceID
        self.path = path
        self.timestamp = timestamp
        self.category = category
        self.operation = operation
        self.attempts = attempts
        self.retryable = retryable
        self.status = status
        self.resolvedAt = resolvedAt
        self.message = message
    }
}

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
    /// Bounded, local-only diagnostics. Cleartext paths never need to enter OSLog.
    public var failureHistory: [TransferFailure]
    public var latestRunID: UUID?
    public var latestRunStartedAt: Date?
    public var activeRunID: UUID?

    public init(
        inFlight: Int,
        completedPuts: Int,
        failedPuts: Int,
        completedDeletes: Int,
        bytesUploaded: Int64,
        bytesDownloaded: Int64,
        currentName: String?,
        lastError: String?,
        lastRemoteCommitAt: Date?,
        uploadBytesPerSecond: Double,
        updatedAt: Date,
        failureHistory: [TransferFailure] = [],
        latestRunID: UUID? = nil,
        latestRunStartedAt: Date? = nil,
        activeRunID: UUID? = nil
    ) {
        self.inFlight = inFlight
        self.completedPuts = completedPuts
        self.failedPuts = failedPuts
        self.completedDeletes = completedDeletes
        self.bytesUploaded = bytesUploaded
        self.bytesDownloaded = bytesDownloaded
        self.currentName = currentName
        self.lastError = lastError
        self.lastRemoteCommitAt = lastRemoteCommitAt
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.updatedAt = updatedAt
        self.failureHistory = failureHistory
        self.latestRunID = latestRunID
        self.latestRunStartedAt = latestRunStartedAt
        self.activeRunID = activeRunID
    }

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
        updatedAt: Date(timeIntervalSince1970: 0),
        failureHistory: [],
        latestRunID: nil,
        latestRunStartedAt: nil,
        activeRunID: nil
    )

    public var unresolvedFailures: [TransferFailure] {
        failureHistory.filter { $0.status == .unresolved }
    }

    public var currentRunUnresolvedFailures: [TransferFailure] {
        guard let latestRunID else { return [] }
        return failureHistory.filter { $0.runID == latestRunID && $0.status == .unresolved }
    }

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

    private enum CodingKeys: String, CodingKey {
        case inFlight, completedPuts, failedPuts, completedDeletes
        case bytesUploaded, bytesDownloaded, currentName, lastError
        case lastRemoteCommitAt, uploadBytesPerSecond, updatedAt
        case failureHistory, latestRunID, latestRunStartedAt, activeRunID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inFlight = try c.decodeIfPresent(Int.self, forKey: .inFlight) ?? 0
        completedPuts = try c.decodeIfPresent(Int.self, forKey: .completedPuts) ?? 0
        failedPuts = try c.decodeIfPresent(Int.self, forKey: .failedPuts) ?? 0
        completedDeletes = try c.decodeIfPresent(Int.self, forKey: .completedDeletes) ?? 0
        bytesUploaded = try c.decodeIfPresent(Int64.self, forKey: .bytesUploaded) ?? 0
        bytesDownloaded = try c.decodeIfPresent(Int64.self, forKey: .bytesDownloaded) ?? 0
        currentName = try c.decodeIfPresent(String.self, forKey: .currentName)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastRemoteCommitAt = try c.decodeIfPresent(Date.self, forKey: .lastRemoteCommitAt)
        uploadBytesPerSecond = try c.decodeIfPresent(Double.self, forKey: .uploadBytesPerSecond) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
        failureHistory = try c.decodeIfPresent([TransferFailure].self, forKey: .failureHistory) ?? []
        latestRunID = try c.decodeIfPresent(UUID.self, forKey: .latestRunID)
        latestRunStartedAt = try c.decodeIfPresent(Date.self, forKey: .latestRunStartedAt)
        activeRunID = try c.decodeIfPresent(UUID.self, forKey: .activeRunID)
    }

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
    private static let maxFailureHistory = 200
    private struct PendingPut {
        let path: String
        let sourceID: String?
        let runID: UUID?
        let operation: String
    }
    private static var pendingPuts: [UUID: PendingPut] = [:]
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

    @discardableResult
    public static func beginRun() -> UUID {
        let id = UUID()
        mutate { snap in
            var s = snap
            s.latestRunID = id
            s.latestRunStartedAt = Date()
            s.activeRunID = id
            s.updatedAt = Date()
            return s
        }
        return id
    }

    public static func endRun(_ id: UUID) {
        mutate { snap in
            var s = snap
            if s.activeRunID == id { s.activeRunID = nil }
            s.updatedAt = Date()
            return s
        }
    }

    public static func clearFailureHistory() {
        mutate { snap in
            var s = snap
            s.failedPuts = 0
            s.lastError = nil
            s.failureHistory = []
            s.latestRunID = nil
            s.latestRunStartedAt = nil
            s.updatedAt = Date()
            return s
        }
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

    @discardableResult
    public static func beginPut(
        name: String,
        sourceID: String? = nil,
        runID: UUID? = nil,
        operation: String = "Upload"
    ) -> UUID {
        let token = UUID()
        lock.lock()
        pendingPuts[token] = PendingPut(
            path: name,
            sourceID: sourceID,
            runID: runID,
            operation: operation
        )
        lock.unlock()
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
        return token
    }

    public static func endPutSuccess(token: UUID, bytes: Int64) {
        var rate = 0.0
        lock.lock()
        let pending = pendingPuts.removeValue(forKey: token)
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
            // Source IDs make Backup paths unambiguous. Finder writes currently
            // provide only a basename, so do not auto-resolve an unrelated item
            // with the same name in another directory.
            if let pending, pending.sourceID != nil {
                let resolvedAt = Date()
                for index in s.failureHistory.indices
                where s.failureHistory[index].status == .unresolved
                    && s.failureHistory[index].path == pending.path
                    && s.failureHistory[index].sourceID == pending.sourceID
                {
                    s.failureHistory[index].status = .resolved
                    s.failureHistory[index].resolvedAt = resolvedAt
                }
            }
            return s
        }
    }

    public static func endPutFailure(token: UUID, error: Error) {
        lock.lock()
        let pending = pendingPuts.removeValue(forKey: token)
        lock.unlock()
        let detail = classify(error)
        mutate { snap in
            var s = snap
            s.inFlight = max(0, s.inFlight - 1)
            s.failedPuts += 1
            s.lastError = detail.message
            let fallback = PendingPut(
                path: s.currentName ?? "Unknown item",
                sourceID: nil,
                runID: s.activeRunID,
                operation: "Upload"
            )
            let context = pending ?? fallback
            s.failureHistory.append(TransferFailure(
                runID: context.runID,
                sourceID: context.sourceID,
                path: context.path,
                category: detail.category,
                operation: context.operation,
                attempts: detail.attempts,
                retryable: detail.retryable,
                message: detail.message
            ))
            if s.failureHistory.count > maxFailureHistory {
                s.failureHistory.removeFirst(s.failureHistory.count - maxFailureHistory)
            }
            s.updatedAt = Date()
            if s.inFlight == 0 { s.currentName = nil }
            return s
        }
    }

    private static func classify(_ error: Error) -> (
        category: String,
        attempts: Int,
        retryable: Bool,
        message: String
    ) {
        let message = String(error.localizedDescription.prefix(240))
        let lower = message.lowercased()
        if lower.contains("access denied") || lower.contains("http 401") || lower.contains("http 403") {
            return ("Authentication", 1, false, message)
        }
        if lower.contains("timed out") || lower.contains("network")
            || lower.contains("not connected") || lower.contains("connection")
            || lower.contains("nsurlerrordomain")
        {
            return ("Network", 5, true, message)
        }
        if lower.contains("encrypt") || lower.contains("cipher") || lower.contains("vault") {
            return ("Vault", 0, false, message)
        }
        if lower.contains("file") || lower.contains("volume") || lower.contains("permission") {
            return ("Local source", 0, true, message)
        }
        return ("Other", 1, true, message)
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
