import Foundation

enum RcloneDriver {
    static var executableURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/rclone",
            "/usr/local/bin/rclone",
            "/usr/bin/rclone",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Also honor PATH for non-sandboxed runs.
        if let found = findOnPATH() { return found }
        return nil
    }

    private static func findOnPATH() -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["rclone"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty, FileManager.default.isExecutableFile(atPath: line) else { return nil }
            return URL(fileURLWithPath: line)
        } catch {
            return nil
        }
    }

    static var isAvailable: Bool { executableURL != nil }

    static var versionLine: String {
        guard let url = executableURL else { return "rclone missing" }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "rclone"
        } catch {
            return "rclone error: \(error.localizedDescription)"
        }
    }

    /// Copy local folder into the cleartext FUSE mount. Blocks until rclone exits.
    @discardableResult
    static func copy(source: String, fuseMount: String, vaultFolder: String, onOutput: ((String) -> Void)? = nil) throws -> Int32 {
        guard let url = executableURL else {
            throw NSError(domain: "CryptoMako", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "rclone not found (install: brew install rclone)",
            ])
        }
        let dest = URL(fileURLWithPath: fuseMount)
            .appendingPathComponent(vaultFolder, isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: dest,
            withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = url
        proc.arguments = [
            "copy", source, dest,
            "-P",
            "--inplace",
            "--transfers", "2",
            "--checkers", "4",
            "--stats", "1s",
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()

        let queue = DispatchQueue(label: "rclone.output")
        queue.async {
            let handle = err.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let s = String(data: data, encoding: .utf8) {
                    onOutput?(s)
                }
            }
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
