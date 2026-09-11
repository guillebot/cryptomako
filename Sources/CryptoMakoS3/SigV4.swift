import CryptoKit
import Foundation

/// Minimal AWS Signature Version 4 signer for S3 GET/LIST requests.
///
/// Hand-rolled rather than pulled from an SDK so the File Provider extension
/// can sign `URLSession` requests without a NIO event-loop group.
enum SigV4 {
    static let emptyPayloadSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    struct Credentials {
        var accessKey: String
        var secretKey: String
        var region: String
        var service: String = "s3"
    }

    /// Returns headers to attach to an unsigned-body GET request.
    static func sign(
        request: URLRequest,
        credentials: Credentials,
        payloadHash: String = emptyPayloadSHA256,
        now: Date = Date()
    ) -> [String: String] {
        guard let url = request.url, let host = url.host else { return [:] }

        let method = request.httpMethod ?? "GET"
        let amzDate = amzDateFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))

        var hostHeader = host
        if let port = url.port, !isDefaultPort(port, scheme: url.scheme) {
            hostHeader = "\(host):\(port)"
        }

        var headers: [String: String] = [
            "host": hostHeader,
            "x-amz-date": amzDate,
            "x-amz-content-sha256": payloadHash,
        ]

        let canonicalURI = canonicalPath(url)
        let canonicalQuery = canonicalQueryString(url)
        let sortedKeys = headers.keys.sorted()
        let canonicalHeaders = sortedKeys
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = sortedKeys.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(credentials.region)/\(credentials.service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let signingKey = derivedKey(
            secret: credentials.secretKey,
            dateStamp: dateStamp,
            region: credentials.region,
            service: credentials.service
        )
        let signature = hex(hmac(key: signingKey, data: Data(stringToSign.utf8)))

        headers["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        return headers
    }

    // MARK: - Canonicalization

    /// S3 signs the path as-sent; segments are encoded but `/` is preserved.
    ///
    /// Read `percentEncodedPath` rather than `URL.path`: the latter strips a
    /// trailing slash, which silently breaks bucket-level requests like
    /// `ListObjectsV2` on `/bucket/` while leaving object GETs working.
    static func canonicalPath(_ url: URL) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? url.path
        let decoded = raw.removingPercentEncoding ?? raw
        let path = decoded.isEmpty ? "/" : decoded
        return uriEncode(path, encodeSlash: false)
    }

    static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty
        else {
            return ""
        }
        return canonicalQueryString(items: items)
    }

    /// The wire query must be byte-identical to this, so callers assign the result
    /// to `percentEncodedQuery`. `URLComponents` leaves `/` raw in query values,
    /// which SigV4 requires as `%2F`.
    static func canonicalQueryString(items: [URLQueryItem]) -> String {
        var pairs: [(name: String, value: String)] = []
        for item in items {
            let name = uriEncode(item.name, encodeSlash: true)
            let value = uriEncode(item.value ?? "", encodeSlash: true)
            pairs.append((name: name, value: value))
        }
        pairs.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        var encoded: [String] = []
        for pair in pairs {
            encoded.append(pair.name + "=" + pair.value)
        }
        return encoded.joined(separator: "&")
    }

    /// RFC 3986 unreserved set; everything else percent-encoded uppercase.
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for byte in Array(string.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            case 0x2F:
                out += encodeSlash ? "%2F" : "/"
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - Crypto

    private static func derivedKey(
        secret: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for step in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: hmac(key: key, data: Data(step.utf8)))
        }
        return key
    }

    private static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
