import SwiftUI
import AppKit
import Domain
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
    @Entry var transcriptStyle: TranscriptStyle = .columns
    /// Palette index per speaker of the meeting on screen (`TranscriptRows.paletteIndices`).
    @Entry var speakerColors: [SpeakerID: Int] = [:]
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

/// Window root: reads the persisted Appearance settings (text size, transcript style) for every view below.
struct AppearanceRoot: ViewModifier {
    @AppStorage(TextSize.key) private var textSize = TextSize.default.rawValue
    @AppStorage(TranscriptStyle.key) private var transcriptStyle = TranscriptStyle.columns.rawValue
    func body(content: Content) -> some View {
        content.textSize(TextSize(stored: textSize)).environment(\.transcriptStyle, TranscriptStyle(stored: transcriptStyle))
    }
}

/// Semantic colours (T43): light and dark variants from `AppPalette`, resolved by the view's effective appearance.
/// Use these instead of `.green` / `.orange` / `.red`, which are too pale on a light background for text.
extension Color {
    static let statusOK = Color(nsColor: .palette(AppPalette.ok))
    static let statusAttention = Color(nsColor: .palette(AppPalette.attention))
    static let statusFailed = Color(nsColor: .palette(AppPalette.failed))
    /// Clickable text (time links): the system link colour.
    static let link = Color(nsColor: .linkColor)

    static func status(_ t: RecorderPresentation.Tone) -> Color {
        switch t { case .green: .statusOK; case .grey: .secondary; case .orange: .statusAttention; case .red: .statusFailed }
    }
    static func status(_ t: MeetingStatusPresentation.Tone) -> Color {
        switch t { case .secondary: .secondary; case .red: .statusFailed; case .orange: .statusAttention }
    }
}

extension NSColor {
    static func palette(_ p: AppPalette.Pair) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = p.resolved(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        }
    }
}

extension AppAppearance {
    /// nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the stored setting to every window, the Settings window and the menu-bar menu.
    @MainActor static func apply(_ stored: String?) { NSApp.appearance = AppAppearance(stored: stored).nsAppearance }
}
