import CryptoMakoShared
import SwiftUI

private struct TextPointAdjustmentKey: EnvironmentKey {
    static let defaultValue = AppPreferences.TextSize.standard.pointAdjustment
}

extension EnvironmentValues {
    var textPointAdjustment: Int {
        get { self[TextPointAdjustmentKey.self] }
        set { self[TextPointAdjustmentKey.self] = newValue }
    }
}

extension View {
    /// Semantic font that grows with Settings → Appearance.
    /// macOS does not resize `Font` text styles when `dynamicTypeSize` changes.
    func appFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.textPointAdjustment) private var adjustment
    var style: Font.TextStyle
    var weight: Font.Weight?
    var design: Font.Design

    func body(content: Content) -> some View {
        content.font(resolved)
    }

    private var resolved: Font {
        let size = CGFloat(style.macPointSize + adjustment)
        var font = Font.system(size: max(size, 9), design: design)
        let resolvedWeight = weight ?? (style == .headline ? .semibold : nil)
        if let resolvedWeight {
            font = font.weight(resolvedWeight)
        }
        return font
    }
}

extension Font.TextStyle {
    /// Default macOS point size for this text style, before the app adjustment.
    var macPointSize: Int {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        default: 13
        }
    }
}
