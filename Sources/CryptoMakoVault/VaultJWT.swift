import CryptoKit
import Foundation

enum VaultJWT {
    struct Header: Decodable {
        var alg: String
        var kid: String?
        var typ: String?
    }

    struct Payload: Decodable {
        var format: Int
        var shorteningThreshold: Int?
        var cipherCombo: String
        var jti: String?
    }

    static func decodeUnverified(_ token: String) throws -> (Header, Payload, String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw VaultError.invalidJWT
        }
        let header = try JSONDecoder().decode(Header.self, from: try base64URLDecode(parts[0]))
        let payload = try JSONDecoder().decode(Payload.self, from: try base64URLDecode(parts[1]))
        return (header, payload, parts[0] + "." + parts[1])
    }

    static func verify(token: String, rawKey: [UInt8]) throws -> Payload {
        let (header, payload, signingInput) = try decodeUnverified(token)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw VaultError.invalidJWT
        }
        let signature = try base64URLDecode(parts[2])
        let message = Data(signingInput.utf8)
        let key = SymmetricKey(data: Data(rawKey))
        let ok: Bool
        switch header.alg.uppercased() {
        case "HS256":
            ok = HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: message, using: key)
        case "HS384":
            ok = HMAC<SHA384>.isValidAuthenticationCode(signature, authenticating: message, using: key)
        case "HS512":
            ok = HMAC<SHA512>.isValidAuthenticationCode(signature, authenticating: message, using: key)
        default:
            throw VaultError.invalidJWT
        }
        guard ok else {
            throw VaultError.invalidJWT
        }
        return payload
    }

    static func sign(header: [String: String], payload: [String: Any], rawKey: [UInt8]) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = base64URLEncode(headerData) + "." + base64URLEncode(payloadData)
        let key = SymmetricKey(data: Data(rawKey))
        let alg = header["alg"]?.uppercased() ?? "HS256"
        let mac: Data
        switch alg {
        case "HS256":
            mac = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key))
        case "HS384":
            mac = Data(HMAC<SHA384>.authenticationCode(for: Data(signingInput.utf8), using: key))
        case "HS512":
            mac = Data(HMAC<SHA512>.authenticationCode(for: Data(signingInput.utf8), using: key))
        default:
            throw VaultError.invalidJWT
        }
        return signingInput + "." + base64URLEncode(mac)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) throws -> Data {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        guard let data = Data(base64Encoded: s) else {
            throw VaultError.invalidJWT
        }
        return data
    }
}
