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
}

/// Colour tokens with light and dark variants (T43). Status colours keep their meaning (green = OK, orange = needs
/// attention, red = failed) at ≥ 4.5:1 on the window background in both appearances; the stock system green and orange
/// are too pale on white for text. `Tests/UI/PaletteContrastTests.swift` checks every pair.
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

    public static let ok = Pair(light: 0x1E7B34, dark: 0x30D158)
    public static let attention = Pair(light: 0xA84F00, dark: 0xFF9230)
    public static let failed = Pair(light: 0xC81E1E, dark: 0xFF6961)

    /// Speaker discs (T35): one set for both appearances, every hue tuned to the same luminance so white initials
    /// read at ≥ 4.5:1 and the disc stands out at ≥ 3:1 from both window backgrounds. No blue: that is the accent.
    public static let speakers: [Pair] = [0x007A90, 0x944DCD, 0xCD297B, 0xB55300, 0x2A7F39, 0x007E71, 0x5F5DE6, 0x926647].map(Pair.init(both:))
    public static let unknownSpeaker = Pair(both: 0x6F6F74)

    /// macOS 26/27 `windowBackgroundColor` / `controlBackgroundColor` and `underPageBackgroundColor` resolved in each
    /// appearance (reference values for the contrast checks; views use the system colours themselves).
    public static let windowBackground = Pair(light: 0xFFFFFF, dark: 0x1E1E1E)
    public static let underPageBackground = Pair(light: 0xF6F6F6, dark: 0x282828)
    /// `linkColor`: time links and other clickable text.
    public static let link = Pair(light: 0x0068DA, dark: 0x419CFF)

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
