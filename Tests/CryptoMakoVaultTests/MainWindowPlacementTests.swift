import CoreGraphics
import XCTest
@testable import CryptoMakoShared

private struct FakeWindow: MainWindowCandidate, Equatable {
    let name: String
    let canBecomeMain: Bool
    let canBecomeKey: Bool
    let hasContentViewController: Bool

    static let statusBar = FakeWindow(
        name: "NSStatusBarWindow", canBecomeMain: false, canBecomeKey: false, hasContentViewController: false
    )
    static let textInputHelper = FakeWindow(
        name: "TextInputUI helper", canBecomeMain: false, canBecomeKey: false, hasContentViewController: false
    )
    static let main = FakeWindow(
        name: "SwiftUI main", canBecomeMain: true, canBecomeKey: true, hasContentViewController: true
    )
}

final class MainWindowSelectionTests: XCTestCase {
    func testPicksMainCapableWindowOverStatusBarAndHelper() {
        let windows: [FakeWindow] = [.statusBar, .textInputHelper, .main]
        XCTAssertEqual(MainWindowSelection.selectMainWindow(from: windows), .main)
    }

    func testReturnsNilWhenOnlyStatusBarAndHelperExist() {
        let windows: [FakeWindow] = [.statusBar, .textInputHelper]
        XCTAssertNil(MainWindowSelection.selectMainWindow(from: windows))
    }

    func testRejectsMainCapableWindowWithoutContentViewController() {
        let bare = FakeWindow(name: "bare", canBecomeMain: true, canBecomeKey: true, hasContentViewController: false)
        XCTAssertNil(MainWindowSelection.selectMainWindow(from: [.statusBar, bare]))
    }

    func testRejectsWindowThatCannotBecomeKey() {
        let noKey = FakeWindow(name: "noKey", canBecomeMain: true, canBecomeKey: false, hasContentViewController: true)
        XCTAssertNil(MainWindowSelection.selectMainWindow(from: [noKey]))
    }

    func testRejectsKeyCapableWindowWithoutContentViewController() {
        let keyBare = FakeWindow(
            name: "keyBare", canBecomeMain: false, canBecomeKey: true, hasContentViewController: false
        )
        XCTAssertNil(MainWindowSelection.selectMainWindow(from: [.statusBar, keyBare]))
        XCTAssertFalse(MainWindowSelection.isMainWindowCandidate(keyBare))
    }

    func testPicksFirstAmongMultipleRealWindows() {
        let first = FakeWindow(name: "first", canBecomeMain: true, canBecomeKey: true, hasContentViewController: true)
        let second = FakeWindow(name: "second", canBecomeMain: true, canBecomeKey: true, hasContentViewController: true)
        XCTAssertEqual(
            MainWindowSelection.selectMainWindow(from: [.statusBar, first, second]),
            first
        )
    }
}

final class MainWindowFrameTests: XCTestCase {
    /// 14" MacBook Pro visible frame (menu bar removed), plus an external display to its right.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)

    private func validated(_ frame: CGRect, screens: [CGRect]? = nil) -> CGRect {
        MainWindowFrame.validatedFrame(frame, screens: screens ?? [laptop], mainScreen: laptop)
    }

    private func centeredDefault() -> CGRect {
        let size = MainWindowFrame.defaultSize
        return CGRect(
            x: (laptop.midX - size.width / 2).rounded(),
            y: (laptop.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    func testTable() {
        struct Case {
            let name: String
            let frame: CGRect
            let screens: [CGRect]?
            let expected: CGRect?
        }
        let healthy = CGRect(x: 240, y: 180, width: 900, height: 700)
        let offDisconnected = CGRect(x: 2200, y: 300, width: 900, height: 700)
        let cases: [Case] = [
            Case(
                name: "500x500 at origin is undersized: default size, kept in the corner, fitted on screen",
                frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                screens: nil,
                expected: CGRect(x: 0, y: 0, width: 820, height: 640)
            ),
            Case(
                name: "below minimum on screen: default size from its top-left, fitted on screen",
                frame: CGRect(x: 300, y: 200, width: 600, height: 400),
                screens: nil,
                expected: CGRect(x: 300, y: 0, width: 820, height: 640)
            ),
            Case(
                name: "shipped 1.0.9 saved frame (900x548): only the short height is reset, top-left kept",
                frame: CGRect(x: 1150, y: 656, width: 900, height: 548),
                screens: [CGRect(x: 0, y: 0, width: 3200, height: 1737)],
                expected: CGRect(x: 1150, y: 564, width: 900, height: 640)
            ),
            Case(
                name: "undersized and off every screen: default size, centered",
                frame: CGRect(x: 5000, y: 5000, width: 500, height: 500),
                screens: nil,
                expected: centeredDefault()
            ),
            Case(
                name: "entirely on a disconnected external screen: keep size, centered",
                frame: offDisconnected,
                screens: nil,
                expected: CGRect(
                    x: (laptop.midX - 450).rounded(), y: (laptop.midY - 350).rounded(), width: 900, height: 700
                )
            ),
            Case(
                name: "same frame while the external screen is connected: unchanged",
                frame: offDisconnected,
                screens: [laptop, external],
                expected: offDisconnected
            ),
            Case(
                name: "healthy frame: unchanged",
                frame: healthy,
                screens: nil,
                expected: healthy
            ),
            Case(
                name: "exactly minimum size, title bar flush with menu bar: unchanged",
                frame: CGRect(x: 0, y: 944 - 588, width: 620, height: 588),
                screens: nil,
                expected: CGRect(x: 0, y: 944 - 588, width: 620, height: 588)
            ),
            Case(
                name: "mostly off the left edge with 100pt of title bar showing: unchanged",
                frame: CGRect(x: -800, y: 100, width: 900, height: 700),
                screens: nil,
                expected: CGRect(x: -800, y: 100, width: 900, height: 700)
            ),
            Case(
                name: "body on screen but title bar above the top: centered",
                frame: CGRect(x: 200, y: 600, width: 900, height: 700),
                screens: nil,
                expected: CGRect(
                    x: (laptop.midX - 450).rounded(), y: (laptop.midY - 350).rounded(), width: 900, height: 700
                )
            ),
            Case(
                name: "only 40pt of title bar on screen horizontally: centered",
                frame: CGRect(x: 1472, y: 100, width: 900, height: 700),
                screens: nil,
                expected: CGRect(
                    x: (laptop.midX - 450).rounded(), y: (laptop.midY - 350).rounded(), width: 900, height: 700
                )
            ),
        ]
        for c in cases {
            XCTAssertEqual(validated(c.frame, screens: c.screens), c.expected, c.name)
        }
    }

    func testOversizedFrameIsClampedToScreenWhenRecentered() {
        let huge = CGRect(x: 5000, y: 5000, width: 3000, height: 2000)
        let result = validated(huge)
        XCTAssertEqual(result, laptop)
    }

    func testNoScreensOnlyFixesSize() {
        let frame = CGRect(x: 10, y: 10, width: 500, height: 500)
        let result = MainWindowFrame.validatedFrame(frame, screens: [], mainScreen: nil)
        XCTAssertEqual(result, CGRect(x: 10, y: -130, width: 820, height: 640))
        let healthy = CGRect(x: 10, y: 10, width: 900, height: 700)
        XCTAssertEqual(MainWindowFrame.validatedFrame(healthy, screens: [], mainScreen: nil), healthy)
    }

    func testFrameFlushOnExternalScreenBoundaryIsUnchanged() {
        // Title bar sits entirely on the external display, flush with its left edge
        // (the gap between laptop and external). Must not re-center onto the laptop.
        let onBoundary = CGRect(x: external.minX, y: 100, width: 900, height: 700)
        let result = MainWindowFrame.validatedFrame(
            onBoundary, screens: [laptop, external], mainScreen: laptop
        )
        XCTAssertEqual(result, onBoundary)
        XCTAssertTrue(MainWindowFrame.titleBarIsReachable(onBoundary, screens: [laptop, external]))
    }

    func testTitleBarStraddlingDisplayGapUsesScreenWithMoreOverlap() {
        // 100pt of title bar on the laptop, rest on the external — still reachable.
        let straddling = CGRect(x: laptop.maxX - 100, y: 100, width: 900, height: 700)
        let result = MainWindowFrame.validatedFrame(
            straddling, screens: [laptop, external], mainScreen: laptop
        )
        XCTAssertEqual(result, straddling)
    }
}
