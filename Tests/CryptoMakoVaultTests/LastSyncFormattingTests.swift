import XCTest
@testable import CryptoMakoShared

final class LastSyncFormattingTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(
            from: DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second
            )
        )!
    }

    func testRelativeAgeUnits() {
        let now = utcDate(2026, 11, 9, 8, 0, 0)
        let cases: [(TimeInterval, String)] = [
            (0, "just now"),
            (1, "just now"),
            (59, "just now"),
            (60, "1 minute ago"),
            (90, "1 minute ago"),
            (119, "1 minute ago"),
            (120, "2 minutes ago"),
            (3599, "59 minutes ago"),
            (3600, "1 hour ago"),
            (3600 * 10, "10 hours ago"),
            (3600 * 47, "47 hours ago"),
            (3600 * 48 - 1, "47 hours ago"),
            (3600 * 48, "2 days ago"),
            (86_400 * 3, "3 days ago"),
            (86_400 * 10, "10 days ago"),
        ]
        for (ago, want) in cases {
            let got = LastSyncFormatting.relativeAge(from: now.addingTimeInterval(-ago), now: now)
            XCTAssertEqual(got, want, "ago=\(ago)s")
        }
    }

    func testRelativeAgeFutureIsJustNow() {
        let now = utcDate(2026, 11, 9, 8, 0, 0)
        let future = now.addingTimeInterval(120)
        XCTAssertEqual(LastSyncFormatting.relativeAge(from: future, now: now), "just now")
    }

    func testAbsoluteLocalUTC() {
        let stamp = utcDate(2026, 11, 8, 22, 14, 0)
        XCTAssertEqual(
            LastSyncFormatting.absoluteLocal(stamp, timeZone: utc),
            "2026-11-08 22:14"
        )
    }

    func testSourceLineNeverSynced() {
        let now = utcDate(2026, 11, 9, 8, 14, 0)
        XCTAssertEqual(
            LastSyncFormatting.sourceLine(lastFullSyncAt: nil, now: now, timeZone: utc),
            "Never synced"
        )
    }

    func testSourceLineWithStamp() {
        let now = utcDate(2026, 11, 9, 8, 14, 0)
        let at = utcDate(2026, 11, 8, 22, 14, 0) // 10 hours earlier
        XCTAssertEqual(
            LastSyncFormatting.sourceLine(lastFullSyncAt: at, now: now, timeZone: utc),
            "Last sync on 2026-11-08 22:14 (10 hours ago)"
        )
    }

    func testAbsoluteAndRelative() {
        let now = utcDate(2026, 11, 8, 22, 16, 0)
        let at = utcDate(2026, 11, 8, 22, 14, 0)
        XCTAssertEqual(
            LastSyncFormatting.absoluteAndRelative(at, now: now, timeZone: utc),
            "2026-11-08 22:14 (2 minutes ago)"
        )
    }
}
