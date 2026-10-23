import CoreGraphics
import Foundation

/// The parts of a window that decide whether it may be brought front as the app's main window.
/// `NSApp.windows` also holds status-bar and OS input helper windows that must never be targeted.
public protocol MainWindowCandidate {
    var canBecomeMain: Bool { get }
    var canBecomeKey: Bool { get }
    var hasContentViewController: Bool { get }
}

public enum MainWindowSelection {
    public static func isMainWindowCandidate(_ window: some MainWindowCandidate) -> Bool {
        window.canBecomeMain && window.canBecomeKey && window.hasContentViewController
    }

    /// First window that can act as the main window, or nil. Never falls back to an arbitrary window.
    public static func selectMainWindow<W: MainWindowCandidate>(from windows: [W]) -> W? {
        windows.first(where: isMainWindowCandidate)
    }
}

/// Sanity checks for a restored main-window frame, in AppKit screen coordinates (origin bottom-left).
public enum MainWindowFrame {
    /// ContentView's minimum content size; the window frame (content plus title bar) must be at least this.
    public static let minimumSize = CGSize(width: 620, height: 560)
    public static let defaultSize = CGSize(width: 820, height: 640)
    public static let titleBarHeight: CGFloat = 28
    /// How much of the title bar must land on some screen for the user to be able to grab it.
    public static let minimumVisibleTitleBar = CGSize(width: 80, height: 24)

    /// Returns `frame` unchanged when it is usable.
    /// - Any dimension below `minimumSize` is reset to `defaultSize` for that dimension, keeping the
    ///   top-left corner, and the result is nudged to fit the screen it sits on.
    /// - A frame whose title bar cannot be grabbed on any screen is re-centered on `mainScreen`.
    /// `screens` and `mainScreen` are visible frames (menu bar and Dock excluded).
    public static func validatedFrame(
        _ frame: CGRect,
        screens: [CGRect],
        mainScreen: CGRect?
    ) -> CGRect {
        let undersized = frame.width < minimumSize.width || frame.height < minimumSize.height
        if !undersized, reachableScreen(for: frame, screens: screens) != nil {
            return frame
        }
        var result = frame
        if undersized {
            let width = frame.width < minimumSize.width ? defaultSize.width : frame.width
            let height = frame.height < minimumSize.height ? defaultSize.height : frame.height
            result = CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
        }
        if let screen = reachableScreen(for: result, screens: screens) {
            return undersized ? fitted(result, in: screen) : result
        }
        guard let target = mainScreen ?? screens.first else { return result }
        return centered(result.size, in: target)
    }

    public static func titleBarIsReachable(_ frame: CGRect, screens: [CGRect]) -> Bool {
        reachableScreen(for: frame, screens: screens) != nil
    }

    /// The screen showing the most of the title bar, if any shows enough of it to drag the window.
    private static func reachableScreen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        let strip = CGRect(
            x: frame.minX,
            y: frame.maxY - titleBarHeight,
            width: frame.width,
            height: titleBarHeight
        )
        let neededHeight = min(minimumVisibleTitleBar.height, strip.height)
        var best: (screen: CGRect, area: CGFloat)?
        for screen in screens {
            let overlap = strip.intersection(screen)
            guard !overlap.isNull,
                  overlap.width >= minimumVisibleTitleBar.width,
                  overlap.height >= neededHeight
            else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen
    }

    /// Shifts `frame` (and shrinks it, never below `minimumSize`) so it lies within `screen`.
    /// When it still cannot fit, the top-left corner wins so the title bar stays on screen.
    private static func fitted(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(frame.width, max(screen.width, minimumSize.width))
        let height = min(frame.height, max(screen.height, minimumSize.height))
        var x = frame.minX
        var maxY = frame.maxY
        if x + width > screen.maxX { x = screen.maxX - width }
        if x < screen.minX { x = screen.minX }
        if maxY - height < screen.minY { maxY = screen.minY + height }
        if maxY > screen.maxY { maxY = screen.maxY }
        return CGRect(x: x, y: maxY - height, width: width, height: height)
    }

    private static func centered(_ size: CGSize, in screen: CGRect) -> CGRect {
        let width = min(size.width, max(screen.width, minimumSize.width))
        let height = min(size.height, max(screen.height, minimumSize.height))
        return CGRect(
            x: (screen.midX - width / 2).rounded(),
            y: (screen.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }
}
