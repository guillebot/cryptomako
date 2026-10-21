import CryptoKit
import Foundation

public struct S3Settings: Sendable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKey: String
    public var secretKey: String
    public var pathStyle: Bool

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        accessKey: String,
        secretKey: String,
        pathStyle: Bool = true
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.pathStyle = pathStyle
    }
}

/// S3 client built on `URLSession` + hand-rolled SigV4.
///
/// Deliberately free of SwiftNIO: a File Provider extension is memory-capped and
/// cannot afford an event-loop group, and `fetchContents` wants downloads written
/// straight to a file URL.
public final class S3ObjectStore: ObjectStore {
    private let settings: S3Settings
    /// Pool of URLSessions. CFNetwork HTTP/2 multiplexes an entire session onto
    /// one TCP connection per host; Zscaler-style middleboxes often rate-limit
    /// that single flow to ~1 Mbps. Separate sessions → separate TCP connections
    /// so Backup Sync concurrency can actually fill the uplink.
    private let sessions: [URLSession]
    private let sessionPickLock = NSLock()
    private var sessionPick: Int = 0

    /// - Parameter configureSession: Optional mutator for each pooled
    ///   `URLSessionConfiguration` (e.g. apply app-group proxy preferences).
    ///   Invoked before the session is created; not used when `session` is injected.
    public init(
        settings: S3Settings,
        session: URLSession? = nil,
        configureSession: ((URLSessionConfiguration) -> Void)? = nil
    ) {
        // Product policy: HTTPS/ATS only for real pooled sessions.
        // Injected sessions (unit tests with MockURLProtocol) may use http://.
        if session == nil {
            let scheme = settings.endpoint.scheme?.lowercased() ?? ""
            precondition(
                scheme == "https",
                "CryptoMako requires https:// S3 endpoints (got \(settings.endpoint.absoluteString))"
            )
        }
        self.settings = settings
        if let session {
            self.sessions = [session]
        } else {
            // MinIO GETs must never hit URLCache: a stale masterkey.cryptomator
            // from before a vault rewrite makes unlock fail while boto/fresh
            // sessions succeed.
            func makeConfig() -> URLSessionConfiguration {
                let config = URLSessionConfiguration.ephemeral
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.urlCache = nil
                // Per-session cap; pool size multiplies total connections under HTTP/2.
                config.httpMaximumConnectionsPerHost = 8
                config.httpShouldUsePipelining = true
                config.timeoutIntervalForRequest = 600
                config.timeoutIntervalForResource = 86_400
                configureSession?(config)
                return config
            }
            // 16 sessions × 8 conn/host ≈ plenty of parallel TCP flows through a
            // middlebox that throttles per connection.
            self.sessions = (0..<16).map { _ in URLSession(configuration: makeConfig()) }
        }
    }

    private func nextSession() -> URLSession {
        sessionPickLock.lock()
        defer { sessionPickLock.unlock() }
        let s = sessions[sessionPick % sessions.count]
        sessionPick &+= 1
        return s
    }

    /// Kept for symmetry with the previous NIO-backed client; `URLSession` needs no teardown.
    public func shutdown() async throws {}

    public func getObject(key: String) async throws -> Data {
        let request = try signedRequest(method: "GET", key: key, query: [])
        let (data, response) = try await send(request, key: key)
        try check(response, key: key, body: data)
