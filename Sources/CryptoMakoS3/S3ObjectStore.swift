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
        return data
    }

    public func headObject(key: String) async throws -> ListedObject {
        let request = try signedRequest(method: "HEAD", key: key, query: [])
        let (_, response) = try await send(request, key: key)
        try check(response, key: key, body: nil)
        guard let http = response as? HTTPURLResponse else {
            throw ObjectStoreError.transport("HEAD returned a non-HTTP response")
        }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0
        let eTag = http.value(forHTTPHeaderField: "ETag")?
            .replacingOccurrences(of: "\"", with: "")
        return ListedObject(key: key, size: length, eTag: eTag)
    }

    public func getObject(key: String, to fileURL: URL) async throws {
        let request = try signedRequest(method: "GET", key: key, query: [])
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await nextSession().download(for: request)
        } catch {
            throw ObjectStoreError.transport(describe(error))
        }
        do {
            try check(response, key: key, body: nil)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
    }

    public func listImmediate(prefix: String) async throws -> PrefixListing {
        var objects: [ListedObject] = []
        var prefixes: [String] = []
        var token: String?

        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "max-keys", value: "1000"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let token {
                query.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let request = try signedRequest(method: "GET", key: "", query: query)
            let (data, response) = try await send(request, key: prefix)
            try check(response, key: prefix, body: data)

            let result = try ListObjectsParser.parse(data)
            objects.append(contentsOf: result.listing.objects)
            prefixes.append(contentsOf: result.listing.commonPrefixes)
            token = result.isTruncated ? result.nextContinuationToken : nil
        } while token != nil

        return PrefixListing(objects: objects, commonPrefixes: prefixes)
    }


    public func putObject(key: String, data: Data) async throws {
        // Hash the body so MinIO/S3 accept the SigV4 signature. Success means
        // the remote object exists — never treat a local CloudStorage write as done.
        let digest = SHA256.hash(data: data)
        let payloadHash = digest.map { String(format: "%02x", $0) }.joined()
        var request = try signedRequest(method: "PUT", key: key, query: [], payloadHash: payloadHash)
        request.httpBody = data
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (body, response) = try await send(request, key: key)
        try check(response, key: key, body: body)
        // PUT HTTP 2xx is durable success. The follow-up HEAD doubled RTT per object
        // and starved Backup Sync on latency-bound uplinks (small-file death << 1 Mbps).
    }

    /// Stream ciphertext from disk with UNSIGNED-PAYLOAD (no full-file RAM + SHA256).
    /// Overrides the protocol default that `Data(contentsOf:)` + hashed put — that path
    /// was a primary Backup Sync throughput / memory bottleneck.
    public func putObject(key: String, from fileURL: URL) async throws {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var request = try signedRequest(
            method: "PUT",
            key: key,
            query: [],
            payloadHash: "UNSIGNED-PAYLOAD"
        )
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let response: URLResponse
        do {
            (_, response) = try await nextSession().upload(for: request, fromFile: fileURL)
        } catch {
            throw ObjectStoreError.transport(describe(error))
        }
        try check(response, key: key, body: nil)
    }

    public func deleteObject(key: String) async throws {
        let request = try signedRequest(method: "DELETE", key: key, query: [])
        let (body, response) = try await send(request, key: key)
        try check(response, key: key, body: body)
    }

    // MARK: - Request building

    private func signedRequest(method: String, key: String, query: [URLQueryItem], payloadHash: String = SigV4.emptyPayloadSHA256) throws -> URLRequest {
        guard var components = URLComponents(url: settings.endpoint, resolvingAgainstBaseURL: false) else {
            throw ObjectStoreError.transport("bad endpoint")
        }
        if settings.pathStyle {
            components.path = "/" + settings.bucket + (key.isEmpty ? "/" : "/" + key)
        } else {
            guard let host = components.host else {
                throw ObjectStoreError.transport("bad endpoint host")
            }
            components.host = settings.bucket + "." + host
            components.path = key.isEmpty ? "/" : "/" + key
        }
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : SigV4.canonicalQueryString(items: query)

        guard let url = components.url else {
            throw ObjectStoreError.transport("bad request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let headers = SigV4.sign(
            request: request,
            credentials: SigV4.Credentials(
                accessKey: settings.accessKey,
                secretKey: settings.secretKey,
                region: settings.region
            ),
            payloadHash: payloadHash
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(_ request: URLRequest, key: String) async throws -> (Data, URLResponse) {
        do {
            return try await nextSession().data(for: request)
        } catch {
            throw ObjectStoreError.transport(describe(error))
        }
    }

    private func check(_ response: URLResponse, key: String, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 404:
            throw ObjectStoreError.notFound(key)
        case 403:
            let detail = body.flatMap { String(data: $0.prefix(512), encoding: .utf8) } ?? ""
            throw ObjectStoreError.transport("access denied for \(key) (HTTP 403) \(detail)")
        default:
            let detail = body.flatMap { String(data: $0.prefix(512), encoding: .utf8) } ?? ""
            throw ObjectStoreError.transport("HTTP \(http.statusCode) for \(key) \(detail)")
        }
    }

    /// Never interpolate the request: it carries the Authorization header.
    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}
