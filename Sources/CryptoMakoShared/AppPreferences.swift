import Foundation

/// App-wide preferences (proxy, Sync bandwidth). Non-secret fields live in the
/// app-group JSON; proxy password uses Keychain (`AppIdentifiers.proxyPasswordAccount`).
public struct AppPreferences: Codable, Equatable, Sendable {
    public enum ProxyMode: String, Codable, Sendable, CaseIterable, Hashable {
        case system
        case direct
        case custom
    }

    public var proxyMode: ProxyMode
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String

    /// When true, Backup Sync paces puts to approximately `syncUploadCapMbps`.
    public var limitSyncUploadBandwidth: Bool
    /// Target Sync upload rate in megabits/second (decimal Mbps). Ignored when limit is off.
    public var syncUploadCapMbps: Double

    public init(
        proxyMode: ProxyMode = .system,
        proxyHost: String = "",
        proxyPort: Int = 8080,
        proxyUsername: String = "",
        limitSyncUploadBandwidth: Bool = false,
        syncUploadCapMbps: Double = 50
    ) {
        self.proxyMode = proxyMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.limitSyncUploadBandwidth = limitSyncUploadBandwidth
        self.syncUploadCapMbps = syncUploadCapMbps
    }

    public static let `default` = AppPreferences()

    enum CodingKeys: String, CodingKey {
        case proxyMode, proxyHost, proxyPort, proxyUsername
        case limitSyncUploadBandwidth, syncUploadCapMbps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? .system
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? ""
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 8080
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        limitSyncUploadBandwidth = try c.decodeIfPresent(Bool.self, forKey: .limitSyncUploadBandwidth) ?? false
        syncUploadCapMbps = try c.decodeIfPresent(Double.self, forKey: .syncUploadCapMbps) ?? 50
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

    public func save() throws {
        guard let url = Self.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
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
public final class UploadBandwidthLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let rateBytesPerSec: Double
    private var tokens: Double
    private var lastRefill: CFAbsoluteTime

    /// - Parameter bytesPerSecond: Sustained cleartext-byte budget (0 disables).
    public init(bytesPerSecond: Double) {
        self.rateBytesPerSec = max(0, bytesPerSecond)
        self.tokens = self.rateBytesPerSec // 1s burst
        self.lastRefill = CFAbsoluteTimeGetCurrent()
    }

    public static func fromPreferences(_ prefs: AppPreferences = .load()) -> UploadBandwidthLimiter? {
        guard let rate = prefs.syncUploadBytesPerSecond else { return nil }
        return UploadBandwidthLimiter(bytesPerSecond: rate)
    }

    /// Block until `byteCount` tokens are available, then consume them.
    public func acquire(_ byteCount: Int64) async {
        guard rateBytesPerSec > 0, byteCount > 0 else { return }
        let need = Double(byteCount)
        while true {
            let sleepSeconds: Double = lock.withLock {
                refillLocked()
                if tokens >= need {
                    tokens -= need
                    return 0
                }
                let deficit = need - tokens
                tokens = 0
                lastRefill = CFAbsoluteTimeGetCurrent()
                return deficit / rateBytesPerSec
            }
            if sleepSeconds <= 0 { return }
            let ns = UInt64(min(sleepSeconds, 2.0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: max(ns, 1_000_000))
        }
    }

    private func refillLocked() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRefill
        guard elapsed > 0 else { return }
        tokens = min(rateBytesPerSec, tokens + elapsed * rateBytesPerSec)
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
