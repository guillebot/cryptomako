import Foundation

/// Pure upload-progress math and display copy for the Backup UI.
///
/// After the scan finishes, progress is **uploaded / to-upload** (cleartext bytes).
/// Skipped files that are already in the vault are **not** progress toward the
/// upload. During the scan there is no known final to-upload total, so there is
/// no determinate upload fraction — the UI should show an indeterminate scan
/// state instead of a stuck percent.
///
/// Mid-scan remaining copy is deliberately provisional and worded differently
/// from the post-scan "left to upload" line so a climbing discovery tally cannot
/// be read as a fixed remaining-work figure that later "shrinks".
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

    /// Human line for the Backup pane and menu tooltip.
    ///
    /// - Mid-scan: provisional tally (climbs until the walk ends).
    /// - Scan just finished: settled to-upload total.
    /// - Mid-upload: remaining work decreasing.
    /// - Not running (idle / failed / aborted): empty.
    public static func remainingLabel(
        isRunning: Bool,
        walkFinished: Bool,
        filesRemaining: Int,
        bytesRemaining: Int64,
        filesUploaded: Int,
        formatBytes: (Int64) -> String = TransferSnapshot.formatBytes
    ) -> String {
        guard isRunning else { return "" }
        let files = filesRemaining.formatted()
        let bytes = formatBytes(bytesRemaining)
        if !walkFinished {
            return "Still counting upload candidates — \(files) files / \(bytes) so far (rises until scan ends)"
        }
        if filesRemaining == 0, filesUploaded == 0 {
            return "Scan complete — nothing to upload"
        }
        if filesUploaded == 0 {
            return "Scan complete — \(files) files, \(bytes) to upload"
        }
        return "\(files) files, \(bytes) left to upload"
    }

    /// Compact counter row: Discovered is the tree total (Skipped + To upload).
    public static func counterBreakdown(
        filesDiscovered: Int,
        filesSkipped: Int,
        bytesSkipped: Int64,
        filesToUpload: Int,
        bytesToUpload: Int64,
        filesUploaded: Int,
        bytesUploaded: Int64,
        formatBytes: (Int64) -> String = TransferSnapshot.formatBytes
    ) -> String {
        let discovered = filesDiscovered.formatted()
        let skipped = filesSkipped.formatted()
        let toUpload = filesToUpload.formatted()
        let uploaded = filesUploaded.formatted()
        let skippedBytes = formatBytes(bytesSkipped)
        let toUploadBytes = formatBytes(bytesToUpload)
        let uploadedBytes = formatBytes(bytesUploaded)
        return "Discovered \(discovered) = Skipped \(skipped) (\(skippedBytes)) + To upload \(toUpload) (\(toUploadBytes)) · Uploaded \(uploaded) (\(uploadedBytes))"
    }

    /// Short caption under the progress bar while the walk is still running.
    public static var scanningCaption: String {
        "Scan still counting — figure above is provisional; uploads start at 0% when the scan finishes."
    }
}
