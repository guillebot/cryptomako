import XCTest
@testable import CryptoMakoShared

final class FinderRefreshSignalPolicyTests: XCTestCase {
    private let floor = FinderRefreshSignalPolicy.minimumInterval

    func testTable() {
        struct Case {
            let name: String
            let last: FinderRefreshSignalCounts
            let current: FinderRefreshSignalCounts
            let elapsed: TimeInterval?
            let force: Bool
            let expect: Bool
        }
        let zero = FinderRefreshSignalCounts(filesUploaded: 0, filesDeleted: 0)
        let uploaded = FinderRefreshSignalCounts(filesUploaded: 10, filesDeleted: 0)
        let moreUploaded = FinderRefreshSignalCounts(filesUploaded: 11, filesDeleted: 0)
        let deleted = FinderRefreshSignalCounts(filesUploaded: 10, filesDeleted: 3)

        let cases: [Case] = [
            Case(
                name: "no change -> no signal",
                last: uploaded, current: uploaded, elapsed: floor + 1, force: false, expect: false
            ),
            Case(
                name: "no change even with nil elapsed -> no signal",
                last: zero, current: zero, elapsed: nil, force: false, expect: false
            ),
            Case(
                name: "change under time floor -> no signal",
                last: uploaded, current: moreUploaded, elapsed: floor - 0.001, force: false, expect: false
            ),
            Case(
                name: "change under floor with force -> signal",
                last: uploaded, current: moreUploaded, elapsed: 1, force: true, expect: true
            ),
            Case(
                name: "change past time floor -> signal",
                last: uploaded, current: moreUploaded, elapsed: floor, force: false, expect: true
            ),
            Case(
                name: "delete count advance past floor -> signal",
                last: uploaded, current: deleted, elapsed: floor, force: false, expect: true
            ),
            Case(
                name: "first change in run (nil elapsed) -> signal immediately",
                last: zero, current: uploaded, elapsed: nil, force: false, expect: true
            ),
            Case(
                name: "completion force with no count change -> always signal",
                last: uploaded, current: uploaded, elapsed: 0, force: true, expect: true
            ),
            Case(
                name: "completion force under floor -> always signal",
                last: uploaded, current: moreUploaded, elapsed: 0.5, force: true, expect: true
            ),
        ]
        for c in cases {
            let got = FinderRefreshSignalPolicy.shouldSignal(
                lastSignaled: c.last,
                current: c.current,
                elapsedSinceLastSignal: c.elapsed,
                force: c.force
            )
            XCTAssertEqual(got, c.expect, c.name)
        }
    }
}
