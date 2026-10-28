public import Foundation

/// Settings → Appearance → Appearance (T43): follow the system, or force light or dark. Applied app-wide through
/// `NSApp.appearance`, so the main window, Settings and the menu-bar menu all follow it.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public static let key = "appearance"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// Unknown or missing stored values read as Match system.
    public init(stored: String?) { self = stored.flatMap(AppAppearance.init(rawValue:)) ?? .system }

    /// The toolbar sun/moon toggle (T44): always the opposite of what is on screen now, so the first click away from
    /// Match system picks the other appearance.
    public static func toggled(effectiveIsDark: Bool) -> AppAppearance { effectiveIsDark ? .light : .dark }
    /// Tooltip of the toolbar toggle; also its VoiceOver label without the shortcut.
    public static func toggleHelp(effectiveIsDark: Bool) -> String {
        "Switch to \(effectiveIsDark ? "light" : "dark") mode (⌘⇧L)"
    }
    /// View-menu item title.
    public static func toggleMenuTitle(effectiveIsDark: Bool) -> String {
        "Switch to \(effectiveIsDark ? "Light" : "Dark") Mode"
    }
}

/// Colour tokens with light and dark variants (T43), now the Inner Circle / Forest identity (docs/design-handoff): cream
/// surfaces and wine accents in light, forest surfaces with cream text and blush accents in dark. The app reads the same
/// values as named colours from `App/Resources/Assets.xcassets` (`AmaranthCanvas` …); these copies feed the contrast
/// checks in `Tests/UI/PaletteContrastTests.swift`, which also check the catalog matches them.
public enum AppPalette {
    public struct RGB: Hashable, Sendable {
        public var r, g, b: UInt8
        public init(_ hex: UInt32) { r = UInt8(hex >> 16 & 0xFF); g = UInt8(hex >> 8 & 0xFF); b = UInt8(hex & 0xFF) }
        public var red: Double { Double(r) / 255 }
        public var green: Double { Double(g) / 255 }
        public var blue: Double { Double(b) / 255 }
    }

    public struct Pair: Hashable, Sendable {
        public var light, dark: RGB
        public init(light: UInt32, dark: UInt32) { self.light = RGB(light); self.dark = RGB(dark) }
        public init(both: UInt32) { self.init(light: both, dark: both) }
        public func resolved(dark isDark: Bool) -> RGB { isDark ? dark : light }
    }

    /// Brand tokens, keyed by their asset-catalog names.
    /// Sidebar, toolbar area and the playback strip.
    public static let canvas = Pair(light: 0xF3ECE5, dark: 0x1D2621)
    /// Notes, transcript, fields and dialogs.
    public static let surface = Pair(light: 0xFFFAF5, dark: 0x28342C)
    public static let text = Pair(light: 0x382A2F, dark: 0xF5F0E6)
    /// Metadata and secondary copy.
    public static let secondaryText = Pair(light: 0x716068, dark: 0xB9C3B5)
    /// Selected tabs, time and source links, playback, focus and emphasised actions.
    public static let accent = Pair(light: 0x752C44, dark: 0xE3A4B6)
    /// Local status and botanical detail.
    public static let sage = Pair(light: 0x416552, dark: 0xA5C5A2)
    /// Control outlines and structural dividers.
    public static let controlBorder = Pair(light: 0x97828B, dark: 0x738375)
    /// The selected meeting row (with an accent edge).
    public static let selection = Pair(light: 0xE9DCD9, dark: 0x3C4138)
    /// Labels on a filled accent control: cream in light, forest in dark (not white).
    public static let onAccent = Pair(light: 0xFFFAF5, dark: 0x28342C)
    /// Audio-quality notices.
    public static let warning = Pair(light: 0x8D431A, dark: 0xEDB48B)
    /// Destructive actions, failures and the recording dot (always beside a word or shape).
    public static let danger = Pair(light: 0x9A343E, dark: 0xEDB0B9)

    /// Every brand token with its asset-catalog name.
    public static let named: [(name: String, pair: Pair)] = [
        ("AmaranthCanvas", canvas), ("AmaranthSurface", surface), ("AmaranthText", text), ("AmaranthSecondaryText", secondaryText),
        ("AmaranthAccent", accent), ("AmaranthSage", sage), ("AmaranthControlBorder", controlBorder), ("AmaranthSelection", selection),
        ("AmaranthOnAccent", onAccent), ("AmaranthWarning", warning), ("AmaranthDanger", danger),
    ]

    /// Status colours keep their meaning (green = OK, orange = needs attention, red = failed), always with an icon or word.
    public static let ok = sage
    public static let attention = warning
    public static let failed = danger

    /// Speaker discs (T35): every hue tuned to the same luminance so the initials read at ≥ 4.5:1 and the disc stands
    /// out at ≥ 3:1 from both surfaces. Dark mode uses the same hues mixed toward cream, with forest initials (the Forest
    /// surface is too light for the deep discs). Names always carry the speaker; the disc is a supporting marker.
    public static let speakers: [Pair] = [
        Pair(light: 0x007A90, dark: 0x459BA8), Pair(light: 0x944DCD, dark: 0xAE79D4), Pair(light: 0xCD297B, dark: 0xDA699D),
        Pair(light: 0xB55300, dark: 0xC77F40), Pair(light: 0x2A7F39, dark: 0x619E68), Pair(light: 0x007E71, dark: 0x459E92),
        Pair(light: 0x5F5DE6, dark: 0x8885E6), Pair(light: 0x926647, dark: 0xAB886F),
    ]
    public static let unknownSpeaker = Pair(light: 0x6F6F74, dark: 0x908F90)
    /// Initials and glyphs on a speaker disc.
    public static let speakerInitials = Pair(light: 0xFFFFFF, dark: 0x1D2621)

    /// Backgrounds text is drawn on (reference values for the contrast checks).
    public static let windowBackground = surface
    public static let underPageBackground = canvas
    /// Clickable text (time links, sources): the accent.
    public static let link = accent

    /// Opacity of the tinted strips behind status text (attention banners, the failed-region row).
    public static let tintOpacity = 0.12

    /// WCAG 2 relative luminance.
    public static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    /// WCAG 2 contrast ratio (1…21).
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` at `opacity` composited over an opaque `bottom` (how a tinted background is seen).
    public static func over(_ top: RGB, _ opacity: Double, _ bottom: RGB) -> RGB {
        func mix(_ t: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(t) * opacity + Double(b) * (1 - opacity)).rounded()) }
        return RGB(UInt32(mix(top.r, bottom.r)) << 16 | UInt32(mix(top.g, bottom.g)) << 8 | UInt32(mix(top.b, bottom.b)))
    }
}
