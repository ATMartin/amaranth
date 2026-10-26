import SwiftUI
import Presentation

/// Compact typography and spacing tokens (T36). Sizes are points at the Default text size and are multiplied by the
/// Settings → Appearance text size through `\.textScale`. Use `.appFont(_:)` instead of system text styles in the
/// meeting views (sidebar, header, transcript, notes) so the setting reaches them.
enum AppStyle {
    enum Role {
        case title, sectionTitle, headline, body, callout, caption, caption2

        var size: CGFloat {
            switch self {
            case .title: 17
            case .sectionTitle: 14
            case .headline, .body: 12
            case .callout: 11.5
            case .caption: 11
            case .caption2: 10
            }
        }
        var weight: Font.Weight {
            switch self {
            case .title: .bold
            case .sectionTitle, .headline: .semibold
            default: .regular
            }
        }
    }

    /// 8-pt grid, with a half step for tight rows.
    static let half: CGFloat = 4
    static let grid: CGFloat = 8
    static let double: CGFloat = 16
}

extension EnvironmentValues {
    @Entry var textScale: CGFloat = 1
}

private struct AppFont: ViewModifier {
    let role: AppStyle.Role
    let weight: Font.Weight?
    let monospacedDigit: Bool
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let font = Font.system(size: role.size * scale, weight: weight ?? role.weight)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func appFont(_ role: AppStyle.Role, weight: Font.Weight? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(AppFont(role: role, weight: weight, monospacedDigit: monospacedDigit))
    }

    /// Applies a stored text size to a view tree (window roots and self-tests).
    func textSize(_ size: TextSize) -> some View { environment(\.textScale, CGFloat(size.scale)) }
}

/// Window root: reads the persisted setting so every view below gets the scale.
struct TextSizeRoot: ViewModifier {
    @AppStorage(TextSize.key) private var stored = TextSize.default.rawValue
    func body(content: Content) -> some View { content.textSize(TextSize(stored: stored)) }
}
