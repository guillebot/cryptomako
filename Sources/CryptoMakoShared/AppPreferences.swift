import Foundation

/// App-wide preferences (proxy, Sync bandwidth). Non-secret fields live in the
/// app-group JSON; proxy password uses Keychain (`AppIdentifiers.proxyPasswordAccount`).
public struct AppPreferences: Codable, Equatable, Sendable {
    public enum ProxyMode: String, Codable, Sendable, CaseIterable, Hashable {
        case system
        case direct
        case custom
    }

    /// Backup Sync transfer mode (shared cross-platform prefs key `backupTransferMode`).
    /// - `backup`: put/update only (never delete source; never delete vault extras).
    /// - `sync`: put/update plus delete vault ciphertext missing from source (never delete source).
    public enum BackupTransferMode: String, Codable, Sendable, CaseIterable, Hashable {
        case backup
        case sync
    }

    public var proxyMode: ProxyMode
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String

    /// Prefs key `backupTransferMode`. Default `.backup` (safer: no vault deletes).
    public var backupTransferMode: BackupTransferMode

    /// When true, Backup Sync paces puts to approximately `syncUploadCapMbps`.
    public var limitSyncUploadBandwidth: Bool
    /// Target Sync upload rate in megabits/second (decimal Mbps). Ignored when limit is off.
    public var syncUploadCapMbps: Double

    /// Concurrent Backup Sync puts for small files (default matches BackupSyncEngine legacy constant).
    public var syncSmallPutConcurrency: Int
    /// Concurrent Backup Sync puts for medium files.
    public var syncMediumPutConcurrency: Int
    /// Concurrent Backup Sync puts for large files (memory-bound).
    public var syncLargePutConcurrency: Int

    public init(
        proxyMode: ProxyMode = .system,
        proxyHost: String = "",
        proxyPort: Int = 8080,
        proxyUsername: String = "",
        backupTransferMode: BackupTransferMode = .backup,
        limitSyncUploadBandwidth: Bool = false,
        syncUploadCapMbps: Double = 50,
        syncSmallPutConcurrency: Int = 96,
        syncMediumPutConcurrency: Int = 32,
        syncLargePutConcurrency: Int = 4
    ) {
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.backupTransferMode = backupTransferMode
        self.limitSyncUploadBandwidth = limitSyncUploadBandwidth
        self.syncUploadCapMbps = syncUploadCapMbps
        self.syncSmallPutConcurrency = syncSmallPutConcurrency
        self.syncMediumPutConcurrency = syncMediumPutConcurrency
        self.syncLargePutConcurrency = syncLargePutConcurrency
    }

    public static let `default` = AppPreferences()

    enum CodingKeys: String, CodingKey {
        case proxyMode, proxyHost, proxyPort, proxyUsername
        case backupTransferMode
        case limitSyncUploadBandwidth, syncUploadCapMbps
        case syncSmallPutConcurrency, syncMediumPutConcurrency, syncLargePutConcurrency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? .system
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8080
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        backupTransferMode = try c.decodeIfPresent(BackupTransferMode.self, forKey: .backupTransferMode) ?? .backup
        limitSyncUploadBandwidth = try c.decodeIfPresent(Bool.self, forKey: .limitSyncUploadBandwidth) ?? false
        syncUploadCapMbps = try c.decodeIfPresent(Double.self, forKey: .syncUploadCapMbps) ?? 50
        syncSmallPutConcurrency = try c.decodeIfPresent(Int.self, forKey: .syncSmallPutConcurrency) ?? 96
        syncMediumPutConcurrency = try c.decodeIfPresent(Int.self, forKey: .syncMediumPutConcurrency) ?? 32
        syncLargePutConcurrency = try c.decodeIfPresent(Int.self, forKey: .syncLargePutConcurrency) ?? 4
    }

    /// Clamp worker knobs to safe ranges (fail-closed: never zero / never unbounded).
    public mutating func clampSyncWorkers() {
        syncSmallPutConcurrency = min(max(syncSmallPutConcurrency, 1), 256)
        syncMediumPutConcurrency = min(max(syncMediumPutConcurrency, 1), 128)
        syncLargePutConcurrency = min(max(syncLargePutConcurrency, 1), 16)
        if syncUploadCapMbps < 1 { syncUploadCapMbps = 1 }
    }

    public var clampedSmallPutConcurrency: Int { min(max(syncSmallPutConcurrency, 1), 256) }
    public var clampedMediumPutConcurrency: Int { min(max(syncMediumPutConcurrency, 1), 128) }
    public var clampedLargePutConcurrency: Int { min(max(syncLargePutConcurrency, 1), 16) }

    // MARK: - Locations

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("app-preferences.json")
    }

    public static func load() -> AppPreferences {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return .default
        }
        return prefs
    }

    public func save() throws {
        var copy = self
        copy.clampSyncWorkers()
        guard let url = Self.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(copy).write(to: url, options: .atomic)
    }

    /// Bytes/sec target for Sync pacing, or `nil` when unlimited.
    public var syncUploadBytesPerSecond: Double? {
        guard limitSyncUploadBandwidth, syncUploadCapMbps > 0 else { return nil }
        return syncUploadCapMbps * 1_000_000 / 8
    }

    /// Apply proxy mode onto an ephemeral `URLSessionConfiguration`.
    /// - Parameter password: Keychain proxy password (custom mode only).
    /// - Note: System mode leaves `connectionProxyDictionary` untouched.
    public func applyProxy(to config: URLSessionConfiguration, password: String?) {
        switch proxyMode {
        case .system:
            return
        case .direct:
            // Bypass system HTTP(S) proxies (corporate PAC / Zscaler, etc.).
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
            ]
        case .custom:
            let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, proxyPort > 0, proxyPort <= 65535 else { return }
            var dict: [String: Any] = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: proxyPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: proxyPort,
            ]
            let user = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty {
                dict[kCFProxyUsernameKey as String] = user
                if let password, !password.isEmpty {
                    dict[kCFProxyPasswordKey as String] = password
                }
            }
            config.connectionProxyDictionary = dict
        }
    }
}

/// Token-bucket limiter for Backup Sync put pacing. Shared across put workers.
///
/// The bucket holds at most ~1s of rate (`maxTokens`). Callers must **not** wait for
/// the entire file size to be present before starting a put — `acquire` consumes in
/// chunks as tokens refill. Prefer charging **after** (or during) the transfer so
/// large files can proceed while the sustained average still respects Mbps.
public final class UploadBandwidthLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let rateBytesPerSec: Double
    /// Burst / chunk cap (= 1s of rate). Tokens never accumulate beyond this.
    private let maxTokens: Double
    private var tokens: Double
    private var lastRefill: CFAbsoluteTime

    /// - Parameter bytesPerSecond: Sustained cleartext-byte budget (0 disables).
    public init(bytesPerSecond: Double) {
        self.rateBytesPerSec = max(0, bytesPerSecond)
        self.maxTokens = self.rateBytesPerSec // 1s burst
        self.tokens = self.maxTokens
        self.lastRefill = CFAbsoluteTimeGetCurrent()
    }

    public static func fromPreferences(_ prefs: AppPreferences = .load()) -> UploadBandwidthLimiter? {
        guard let rate = prefs.syncUploadBytesPerSecond else { return nil }
        return UploadBandwidthLimiter(bytesPerSecond: rate)
    }

    /// Consume `byteCount` tokens as the bucket refills.
    ///
    /// - Never requires `byteCount` ≤ `maxTokens` (chunked takes).
    /// - Never zeroes the bucket on deficit (concurrent waiters keep sharing refill).
    /// - No-op when bandwidth limiting is off or `byteCount` ≤ 0.
    /// - Returns early on task cancellation (Cancel path).
    public func acquire(_ byteCount: Int64) async {
        guard rateBytesPerSec > 0, byteCount > 0 else { return }
        var remaining = Double(byteCount)
        while remaining > 0 {
            if Task.isCancelled { return }
            let sleepSeconds: Double = lock.withLock {
                refillLocked()
                // Take whatever is available now — partial progress is required so
                // files larger than the 1s burst can ever finish acquiring.
                if tokens > 0 {
                    let take = min(tokens, remaining)
                    tokens -= take
                    remaining -= take
                    if remaining <= 0 { return 0 }
                }
                // Sleep until we expect another useful chunk. Do **not** reset
                // `tokens` / `lastRefill` — that wiped the bucket and starved peers.
                let want = min(remaining, maxTokens)
                return want / rateBytesPerSec
            }
            if sleepSeconds <= 0 { continue }
            // Short slices so Cancel stays responsive; wake and re-evaluate.
            let slice = min(max(sleepSeconds, 0.001), 0.25)
            let ns = UInt64(slice * 1_000_000_000)
            try? await Task.sleep(nanoseconds: max(ns, 1_000_000))
        }
    }

    private func refillLocked() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRefill
        guard elapsed > 0 else { return }
        tokens = min(maxTokens, tokens + elapsed * rateBytesPerSec)
        lastRefill = now
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
