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

    /// Window text size. `standard` is one Dynamic Type step above the old default
    /// (about 1–2 points). Older preference files decode as `standard`.
    public enum TextSize: String, Codable, Sendable, CaseIterable, Hashable {
        case compact
        case standard
        case large
        case extraLarge

        /// Points added to macOS text styles. Compact is the previous size.
        /// Standard is two points larger. macOS ignores SwiftUI Dynamic Type.
        public var pointAdjustment: Int {
            switch self {
            case .compact: 0
            case .standard: 2
            case .large: 4
            case .extraLarge: 6
            }
        }
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

    /// Prefs key `textSize`. Default `.standard`.
    public var textSize: TextSize

    /// Prefs key `capSMBPutWorkers`. When true (default), Backup Sync caps put
    /// workers for network sources (explicit `smb://` sources and folders on an
    /// smbfs / nfs / afpfs / webdav mount) at `SyncPutWorkerCounts.networkSourceCap`
    /// so the share is not thrashed. Older preference files decode as `true`.
    public var capSMBPutWorkers: Bool

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
        syncLargePutConcurrency: Int = 4,
        textSize: TextSize = .standard,
        capSMBPutWorkers: Bool = true
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
        self.textSize = textSize
        self.capSMBPutWorkers = capSMBPutWorkers
    }

    public static let `default` = AppPreferences()

    enum CodingKeys: String, CodingKey {
        case proxyMode, proxyHost, proxyPort, proxyUsername
        case backupTransferMode
        case limitSyncUploadBandwidth, syncUploadCapMbps
        case syncSmallPutConcurrency, syncMediumPutConcurrency, syncLargePutConcurrency
        case textSize
        case capSMBPutWorkers
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
        textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? .standard
        capSMBPutWorkers = try c.decodeIfPresent(Bool.self, forKey: .capSMBPutWorkers) ?? true
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

    /// Effective Backup Sync put workers for a source (Settings clamp, then the
    /// network-source cap when `capSMBPutWorkers` is on).
    public func effectivePutWorkers(isNetworkSource: Bool) -> SyncPutWorkerCounts {
        SyncPutWorkerCounts.effective(
            small: clampedSmallPutConcurrency,
            medium: clampedMediumPutConcurrency,
            large: clampedLargePutConcurrency,
            isNetworkSource: isNetworkSource,
            capNetworkSources: capSMBPutWorkers
        )
    }

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

    /// Posted after a successful `save()` so a running Backup Sync can hot-reload
    /// bandwidth (workers / excludes still take effect on the next Sync).
    public static let didSaveNotification = Notification.Name("net.gschimmel.cryptomako.appPreferencesDidSave")

    /// `userInfo` key for `didSaveNotification`: cleartext upload budget in bytes/sec
    /// (`0` = unlimited). Observers should prefer this over re-reading disk.
    public static let uploadBytesPerSecondUserInfoKey = "uploadBytesPerSecond"

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
        // Pass the rate in userInfo so Sync does not depend on a post-write disk
        // reload (and so a stale in-memory copy elsewhere cannot undo the cap).
        let rate = copy.syncUploadBytesPerSecond ?? 0
        NotificationCenter.default.post(
            name: Self.didSaveNotification,
            object: nil,
            userInfo: [Self.uploadBytesPerSecondUserInfoKey: rate]
        )
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
///
/// Rate is mutable: Settings can change Mbps (or disable limiting) mid-Sync via
/// `applyPreferences` / `setBytesPerSecond`. In-flight PUTs finish; the next
/// `acquire` (post-put charge) uses the new budget. Rate `0` = unlimited.
public final class UploadBandwidthLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var rateBytesPerSec: Double
    /// Burst / chunk cap (= 1s of rate). Tokens never accumulate beyond this.
    private var maxTokens: Double
    private var tokens: Double
    private var lastRefill: CFAbsoluteTime

    /// - Parameter bytesPerSecond: Sustained cleartext-byte budget (0 disables).
    public init(bytesPerSecond: Double) {
        let rate = max(0, bytesPerSecond)
        self.rateBytesPerSec = rate
        self.maxTokens = rate // 1s burst
        self.tokens = rate
        self.lastRefill = CFAbsoluteTimeGetCurrent()
    }

    /// Limiter that always exists so Sync can hot-reload on/off and Mbps.
    public static func live(from prefs: AppPreferences = .load()) -> UploadBandwidthLimiter {
        UploadBandwidthLimiter(bytesPerSecond: prefs.syncUploadBytesPerSecond ?? 0)
    }

    public static func fromPreferences(_ prefs: AppPreferences = .load()) -> UploadBandwidthLimiter? {
        guard let rate = prefs.syncUploadBytesPerSecond else { return nil }
        return UploadBandwidthLimiter(bytesPerSecond: rate)
    }

    /// Current cleartext-byte budget (0 = unlimited). For tests / diagnostics.
    public var bytesPerSecond: Double {
        lock.withLock { rateBytesPerSec }
    }

    /// Hot-reload from disk prefs (limit toggle + Mbps). Safe while workers `acquire`.
    public func applyPreferences(_ prefs: AppPreferences = .load()) {
        setBytesPerSecond(prefs.syncUploadBytesPerSecond ?? 0)
    }

    /// Update the sustained budget. `0` disables pacing immediately (waiters exit).
    public func setBytesPerSecond(_ bytesPerSecond: Double) {
        lock.withLock {
            let newRate = max(0, bytesPerSecond)
            if rateBytesPerSec > 0 {
                refillLocked()
            }
            let enabling = rateBytesPerSec <= 0 && newRate > 0
            rateBytesPerSec = newRate
            maxTokens = newRate
            if newRate <= 0 {
                tokens = 0
            } else if enabling {
                tokens = maxTokens
            } else {
                tokens = min(tokens, maxTokens)
            }
            lastRefill = CFAbsoluteTimeGetCurrent()
        }
    }

    /// Consume `byteCount` tokens as the bucket refills.
    ///
    /// - Never requires `byteCount` ≤ `maxTokens` (chunked takes).
    /// - Never zeroes the bucket on deficit (concurrent waiters keep sharing refill).
    /// - No-op when bandwidth limiting is off or `byteCount` ≤ 0.
    /// - Re-reads rate each slice so a mid-Sync Settings change applies promptly.
    /// - Returns early on task cancellation (Cancel path).
    public func acquire(_ byteCount: Int64) async {
        guard byteCount > 0 else { return }
        var remaining = Double(byteCount)
        while remaining > 0 {
            if Task.isCancelled { return }
            let sleepSeconds: Double = lock.withLock {
                // Unlimited (or disabled mid-wait): drop remaining charge.
                guard rateBytesPerSec > 0, maxTokens > 0 else {
                    remaining = 0
                    return 0
                }
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
            // Short slices so Cancel + live rate changes stay responsive.
            let slice = min(max(sleepSeconds, 0.001), 0.25)
            let ns = UInt64(slice * 1_000_000_000)
            try? await Task.sleep(nanoseconds: max(ns, 1_000_000))
        }
    }

    private func refillLocked() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRefill
        guard elapsed > 0, rateBytesPerSec > 0 else { return }
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


// MARK: - Put worker counts

/// Small / medium / large put worker counts actually used by Backup Sync.
public struct SyncPutWorkerCounts: Equatable, Sendable {
    public var small: Int
    public var medium: Int
    public var large: Int
    /// True when the network-source cap lowered at least one tier.
    public var isCapped: Bool

    public init(small: Int, medium: Int, large: Int, isCapped: Bool = false) {
        self.small = small
        self.medium = medium
        self.large = large
        self.isCapped = isCapped
    }

    /// Network-source ceiling. Each put reads cleartext from the share before
    /// encrypt+PUT; dozens of parallel ~25 MB reads thrash one SMB mount.
    public static let networkSourceCap = SyncPutWorkerCounts(small: 16, medium: 6, large: 2)

    public var total: Int { small + medium + large }

    /// "16 / 6 / 2"
    public var summary: String { "\(small) / \(medium) / \(large)" }

    /// Pure computation (unit-tested). Inputs are already-clamped Settings values.
    public static func effective(
        small: Int,
        medium: Int,
        large: Int,
        isNetworkSource: Bool,
        capNetworkSources: Bool
    ) -> SyncPutWorkerCounts {
        guard isNetworkSource, capNetworkSources else {
            return SyncPutWorkerCounts(small: small, medium: medium, large: large)
        }
        let cap = networkSourceCap
        let s = min(small, cap.small)
        let m = min(medium, cap.medium)
        let l = min(large, cap.large)
        return SyncPutWorkerCounts(
            small: s, medium: m, large: l,
            isCapped: s < small || m < medium || l < large
        )
    }
}

// MARK: - Network filesystem detection

/// Detects folders that live on a network mount (e.g. a `/Volumes/Share` SMB
/// mount added as a plain local folder rather than an `smb://` source).
public enum NetworkFilesystem {
    /// `statfs.f_fstypename` values treated as network filesystems.
    public static let networkTypeNames: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp"]

    /// Pure: is this `f_fstypename` a network filesystem? (case-insensitive)
    public static func isNetworkTypeName(_ name: String) -> Bool {
        networkTypeNames.contains(name.lowercased())
    }

    /// `statfs` type name for `path`, or nil if it cannot be read.
    public static func typeName(atPath path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        return withUnsafePointer(to: &st.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
    }

    /// True when `path` is on smbfs / nfs / afpfs / webdav (statfs). False if unknown.
    public static func isOnNetworkFilesystem(path: String) -> Bool {
        guard let name = typeName(atPath: path) else { return false }
        return isNetworkTypeName(name)
    }
}
