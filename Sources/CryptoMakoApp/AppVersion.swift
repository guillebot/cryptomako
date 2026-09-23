import Foundation

/// Resolves a human-readable version for About and update checks.
///
/// Packaged `.app` builds get `CFBundleShortVersionString` / `CFBundleVersion`
/// from Xcode (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). SwiftPM
/// `swift run` has neither, so we fall back to a stable label.
enum AppVersion {
    /// Marketing version, e.g. `1.0.0`.
    static var marketing: String {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !short.isEmpty,
           !short.hasPrefix("$(")
        {
            return short
        }
        return "1.0.0-dev"
    }

    /// Build number when present (Xcode), otherwise omitted from display.
    static var build: String? {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty,
              !build.hasPrefix("$(")
        else {
            return nil
        }
        return build
    }

    /// e.g. `1.0.0 (100)` or `1.0.0-dev (swift run)`.
    static var displayString: String {
        if let build {
            return "\(marketing) (\(build))"
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return marketing
        }
        return "\(marketing) (swift run)"
    }
}
