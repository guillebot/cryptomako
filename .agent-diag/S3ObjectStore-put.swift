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
