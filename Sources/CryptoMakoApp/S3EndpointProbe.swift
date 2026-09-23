import Foundation
import Network

/// Lightweight TCP reachability check for the configured S3/MinIO endpoint.
enum S3EndpointProbe {
    /// Returns true if a TCP connection to host:port succeeds within `timeout`.
    /// HTTP status is irrelevant — this is about IP / VPN / route availability.
    static func isReachable(endpointURLString: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: endpointURLString), let host = url.host, !host.isEmpty else {
            return false
        }
        let portValue: UInt16
        if let p = url.port {
            portValue = UInt16(p)
        } else if url.scheme?.lowercased() == "http" {
            portValue = 80
        } else {
            portValue = 443
        }
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var resumed = false
            func finish(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}
