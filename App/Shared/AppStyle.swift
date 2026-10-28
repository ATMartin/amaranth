import SwiftUI
import AppKit
import Domain
import Presentation

/// Typography and spacing tokens (T36; sizes from the Inner Circle handoff: 14 pt body, 12 pt metadata, 25 pt meeting
/// title, nothing essential below 11 pt). Sizes are points at the Default text size and are multiplied by the
/// Settings → Appearance text size through `\.textScale`. Use `.appFont(_:)` instead of system text styles in the
/// meeting views (sidebar, header, transcript, notes) so the setting reaches them. The working UI stays in the system
/// font; only `.display` (meeting titles and a few headings) uses the rounded brand face.
enum AppStyle {
    enum Role {
        case display, title, sectionTitle, headline, body, callout, caption, caption2, eyebrow

        var size: CGFloat {
            switch self {
            case .display: 25
            case .title: 19
            case .sectionTitle: 15
            case .headline, .body: 14
            case .callout: 13
            case .caption: 12
            case .caption2, .eyebrow: 11
            }
        }
        var weight: Font.Weight {
            switch self {
            case .display, .title: .bold
            case .sectionTitle, .headline: .semibold
            case .eyebrow: .medium
            default: .regular
            }
        }
    }

    /// The brand display face, with the rounded system font where it is missing.
    static let displayFamily = "Arial Rounded MT Bold"
    static let hasDisplayFace = NSFont(name: displayFamily, size: 12) != nil
    /// Body line spacing: about 1.5 × the font size in long reading text (notes, transcript).
    static func readingLineSpacing(_ scale: CGFloat) -> CGFloat { 0.4 * Role.body.size * scale }

    /// Inline status and source icons (T45): 11–13 pt, so they sit on the text line instead of competing with it.
    static let iconSmall: CGFloat = 11
    static let icon: CGFloat = 12
    static let iconLarge: CGFloat = 13

    /// Text in the toolbar recorder (Record button and recording strip): a step below the default control size.
    static let toolbarText: CGFloat = 11.5

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
        let size = role.size * scale
        let font: Font = switch role {
        case .display where AppStyle.hasDisplayFace: .custom(AppStyle.displayFamily, fixedSize: size)
        case .display: .system(size: size, weight: .bold, design: .rounded)
        default: .system(size: size, weight: weight ?? role.weight)
        }
        // Eyebrows ("TRANSCRIPT", the header date): small tracked capitals, as in the reference.
        if role == .eyebrow {
            content.font(monospacedDigit ? font.monospacedDigit() : font).textCase(.uppercase).tracking(1.1 * scale)
        } else {
            content.font(monospacedDigit ? font.monospacedDigit() : font)
        }
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

/// Which track a line came from (T45): a small mic or speaker glyph instead of a "MIC" / "SYS" text badge. The tooltip
/// and VoiceOver label carry the words.
struct SourceIcon: View {
    let source: SourceKind
    @Environment(\.textScale) private var scale

    var body: some View {
        let name = source == .microphone ? "Your microphone" : "System audio"
        Image(systemName: RecorderPresentation.symbol(source))
            .font(.system(size: AppStyle.iconSmall * scale)).foregroundStyle(Color.brandSecondary)
            .frame(width: 14 * scale)
            .help(name).accessibilityLabel(name)
    }
}

/// Brand colours (Inner Circle / Forest): the named light/dark colours in `App/Resources/Assets.xcassets`, resolved by
/// each view's effective appearance. `AppPalette` holds the same values for the contrast tests.
extension Color {
    /// Sidebar, toolbar area, playback strip.
    static let canvas = Color("AmaranthCanvas")
    /// Notes, transcript, fields, dialogs.
    static let surface = Color("AmaranthSurface")
    static let brandText = Color("AmaranthText")
    static let brandSecondary = Color("AmaranthSecondaryText")
    /// Selected tabs, links, playback, focus, emphasised actions (also the app's global accent).
    static let brandAccent = Color("AmaranthAccent")
    static let sage = Color("AmaranthSage")
    static let controlBorder = Color("AmaranthControlBorder")
    /// The selected meeting row, paired with an accent edge.
    static let selection = Color("AmaranthSelection")
    /// Labels on a filled accent control.
    static let onAccent = Color("AmaranthOnAccent")

    /// Status colours: they keep their meaning (green = OK, orange = needs attention, red = failed) and always sit beside
    /// an icon or a word.
    static let statusOK = sage
    static let statusAttention = Color("AmaranthWarning")
    static let statusFailed = Color("AmaranthDanger")
    /// Clickable text (time links, sources).
    static let link = brandAccent

    static func status(_ t: RecorderPresentation.Tone) -> Color {
        switch t { case .green: .statusOK; case .grey: .brandSecondary; case .orange: .statusAttention; case .red: .statusFailed }
    }
    static func status(_ t: MeetingStatusPresentation.Tone) -> Color {
        switch t { case .secondary: .brandSecondary; case .red: .statusFailed; case .orange: .statusAttention }
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

    /// What is on screen now, whether forced or following the system.
    @MainActor static var effectiveIsDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// T44: sun/moon toolbar button. Shows where a click goes (sun in dark mode, moon in light mode) and stores Light or
/// Dark; ⌘⇧L lives on the View-menu item, which does the same.
struct AppearanceToggle: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Button { appearance = AppAppearance.toggled(effectiveIsDark: dark).rawValue } label: {
            Label(AppAppearance.toggleMenuTitle(effectiveIsDark: dark), systemImage: dark ? "sun.max" : "moon")
        }
        .help(AppAppearance.toggleHelp(effectiveIsDark: dark))
    }
}
