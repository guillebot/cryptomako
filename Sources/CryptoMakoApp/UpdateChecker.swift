import AppKit
import Foundation

/// Lightweight GitHub Releases check for SwiftPM / unsigned builds.
///
/// A signed `.app` should eventually use Sparkle; this path stays AGPL-friendly
/// (Foundation only) and never crashes when the repo is private or offline.
enum UpdateChecker {
    static let owner = "guillebot"
    static let repo = "cryptomako"
    static let releasesPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases")!

    private static let latestAPI = URL(
        string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
    )!

    enum Outcome: Sendable {
        case upToDate(current: String, latest: String)
        case updateAvailable(current: String, latest: String, htmlURL: URL?)
        case noReleases
        case privateOrMissing
        case networkError(String)
        case unexpected(String)
    }

    @MainActor
    static func checkAndPresent() async {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.alertStyle = .informational

        let outcome = await check()
        switch outcome {
        case let .upToDate(current, latest):
            alert.informativeText = "CryptoMako \(current) is up to date (latest release: \(latest))."
            alert.addButton(withTitle: "OK")
        case let .updateAvailable(current, latest, htmlURL):
            alert.informativeText = """
            A newer release is available.

            Current: \(current)
            Latest: \(latest)

            Open the Releases page to download. Signed .app builds can later use Sparkle for in-app updates.
            """
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "Later")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(htmlURL ?? releasesPageURL)
            }
            return
        case .noReleases:
            alert.informativeText = """
            No published GitHub Releases were found for \(owner)/\(repo).

            Current version: \(AppVersion.displayString)
            """
            alert.addButton(withTitle: "OK")
        case .privateOrMissing:
            alert.informativeText = """
            Could not read releases for \(owner)/\(repo) (404). The repository may be private or missing public Releases.

            Without a token, the GitHub API cannot list private releases. Packaged .app builds can use Sparkle once distribution is set up.

            Current version: \(AppVersion.displayString)
            """
            alert.addButton(withTitle: "OK")
        case let .networkError(message):
            alert.informativeText = """
            Update check failed: \(message)

            Current version: \(AppVersion.displayString)
            """
            alert.addButton(withTitle: "OK")
        case let .unexpected(message):
            alert.informativeText = """
            Unexpected response from GitHub: \(message)

            Current version: \(AppVersion.displayString)
            """
            alert.addButton(withTitle: "OK")
        }
        _ = alert.runModal()
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: latestAPI)
        request.timeoutInterval = 15
        request.setValue("CryptoMako/\(AppVersion.marketing)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unexpected("non-HTTP response")
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                // Private repo, missing repo, or no releases endpoint visibility.
                return .privateOrMissing
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return .unexpected("HTTP \(http.statusCode)\(body.isEmpty ? "" : ": \(body.prefix(120))")")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unexpected("invalid JSON")
            }
            // GitHub returns a message object for some error shapes even with 200 rarely;
            // empty tag means no usable release.
            guard let tag = json["tag_name"] as? String, !tag.isEmpty else {
                return .noReleases
            }
            let latest = normalizeTag(tag)
            let current = normalizeTag(AppVersion.marketing)
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))

            if compareVersions(latest, current) == .orderedDescending {
                return .updateAvailable(current: AppVersion.displayString, latest: latest, htmlURL: htmlURL)
            }
            return .upToDate(current: AppVersion.displayString, latest: latest)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    static func normalizeTag(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") {
            t = String(t.dropFirst())
        }
        // Drop swift-run suffix for comparison.
        if let range = t.range(of: "-dev") {
            t = String(t[..<range.lowerBound])
        }
        return t
    }

    /// Numeric-ish semver compare: `1.2.3` vs `1.10.0`. Non-numeric segments compare as strings.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : "0"
            let b = i < right.count ? right[i] : "0"
            if let ai = Int(a), let bi = Int(b) {
                if ai != bi {
                    return ai < bi ? .orderedAscending : .orderedDescending
                }
            } else {
                let c = a.compare(b, options: .numeric)
                if c != .orderedSame {
                    return c
                }
            }
        }
        return .orderedSame
    }
}
