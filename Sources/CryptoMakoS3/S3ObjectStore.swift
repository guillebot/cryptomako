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
    private let session: URLSession

    public init(settings: S3Settings, session: URLSession? = nil) {
        self.settings = settings
        if let session {
            self.session = session
        } else {
            // MinIO GETs must never hit URLCache: a stale masterkey.cryptomator
            // from before a vault rewrite makes unlock fail while boto/fresh
            // sessions succeed.
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
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
            (tempURL, response) = try await session.download(for: request)
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

    // MARK: - Request building

    private func signedRequest(method: String, key: String, query: [URLQueryItem]) throws -> URLRequest {
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
            )
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(_ request: URLRequest, key: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
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
