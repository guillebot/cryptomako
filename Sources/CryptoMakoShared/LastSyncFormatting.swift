import Foundation

/// Absolute + relative “last sync” copy for Backup source rows (and menu tooltip).
///
/// Relative units (floor, clamped for clock skew):
/// - under 1 minute → `just now`
/// - under 1 hour → `N minute(s) ago`
/// - under 2 days → `N hour(s) ago`
/// - otherwise → `N day(s) ago`
///
/// Pure helpers take an explicit `now` so table tests stay deterministic.
public enum LastSyncFormatting {
    /// Relative age only, e.g. `10 hours ago` / `just now`.
    public static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 172_800 { // 48 hours
            let hours = max(1, seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = max(1, seconds / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// Local wall clock `yyyy-MM-dd HH:mm` (no seconds — keeps the Backup row compact).
    public static func absoluteLocal(
        _ date: Date,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// One compact source-row line.
    /// - Never completed: `Never synced`
    /// - Otherwise: `Last sync on 2026-11-08 22:14 (10 hours ago)`
    public static func sourceLine(
        lastFullSyncAt: Date?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        guard let at = lastFullSyncAt else {
            return "Never synced"
        }
        let absolute = absoluteLocal(at, timeZone: timeZone)
        let relative = relativeAge(from: at, now: now)
        return "Last sync on \(absolute) (\(relative))"
    }

    /// Short tooltip / menu-bar phrase without the “Last sync on” prefix.
    /// `nil` when there is no successful stamp.
    public static func absoluteAndRelative(
        _ date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        "\(absoluteLocal(date, timeZone: timeZone)) (\(relativeAge(from: date, now: now)))"
    }
}
