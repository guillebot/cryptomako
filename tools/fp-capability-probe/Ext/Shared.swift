import FileProvider
import Foundation
import os

let plog = Logger(subsystem: "net.gschimmel.cryptomako.probe", category: "probe")
let probeGroup = "H4K6YW7MQM.group.net.gschimmel.cryptomako"

/// Probe control files live under <group>/fp-probe/ (never touches CryptoMako files).
enum ProbeControl {
    static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: probeGroup)?
            .appendingPathComponent("fp-probe", isDirectory: true)
    }
    static func read(_ name: String) -> String {
        guard let u = dir?.appendingPathComponent(name),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func write(_ name: String, _ value: String) {
        guard let d = dir else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? value.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    static var phase: Int { Int(read("phase")) ?? 1 }
    /// "materialized" (enumeratorForMaterializedItems) or "all".
    static var mode: String { read("mode").isEmpty ? "materialized" : read("mode") }
}
