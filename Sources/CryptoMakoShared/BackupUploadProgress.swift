import Foundation

/// Pure upload-progress math for the Backup UI.
///
/// After the scan finishes, progress is **uploaded / to-upload** (cleartext bytes).
/// Skipped files that are already in the vault are **not** progress toward the
/// upload. During the scan there is no known final to-upload total, so there is
/// no determinate upload fraction — the UI should show an indeterminate scan
/// state instead of a stuck percent.
public enum BackupUploadProgress: Sendable {
    /// `nil` while scanning (no upload percent). After the scan: 0…1 from
    /// `bytesUploaded / bytesToUpload`. Empty to-upload set → 1 (nothing left).
    public static func fraction(
        walkFinished: Bool,
        bytesUploaded: Int64,
        bytesToUpload: Int64
    ) -> Double? {
        guard walkFinished else { return nil }
        guard bytesToUpload > 0 else { return 1 }
        return min(1, max(0, Double(bytesUploaded) / Double(bytesToUpload)))
    }

    /// Label for the big percent: `"Scanning"`, `"N%"`, or `"100%"` when finished.
    public static func percentLabel(
        walkFinished: Bool,
        bytesUploaded: Int64,
        bytesToUpload: Int64,
        jobFinished: Bool = false
    ) -> String {
        if jobFinished { return "100%" }
        guard let frac = fraction(
            walkFinished: walkFinished,
            bytesUploaded: bytesUploaded,
            bytesToUpload: bytesToUpload
        ) else {
            return "Scanning"
        }
        let pct = Int((frac * 100).rounded(.down))
        return "\(pct)%"
    }
}
