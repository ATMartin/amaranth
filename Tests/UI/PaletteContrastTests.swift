import Testing
import Foundation
@testable import Presentation

/// T43 acceptance: WCAG contrast over the colour tokens in both appearances: ≥ 4.5:1 for text, ≥ 3:1 for glyphs.
@Suite("Palette contrast")
struct PaletteContrastTests {
    typealias P = AppPalette
    static let modes: [(String, Bool)] = [("light", false), ("dark", true)]

    @Test func statusTextReadsOnEveryBackgroundItAppearsOn() {
        for (mode, k) in Self.modes {
            for (name, token) in [("ok", P.ok), ("attention", P.attention), ("failed", P.failed)] {
                let fg = token.resolved(dark: k)
                let backgrounds = [("window", P.windowBackground.resolved(dark: k)), ("underPage", P.underPageBackground.resolved(dark: k)),
                                   ("own tint", P.over(fg, P.tintOpacity, P.windowBackground.resolved(dark: k)))]
                for (bgName, bg) in backgrounds {
                    let c = P.contrast(fg, bg)
                    #expect(c >= 4.5, "\(name) on \(bgName) in \(mode): \(c)")
                }
            }
            let link = P.contrast(P.link.resolved(dark: k), P.windowBackground.resolved(dark: k))
            #expect(link >= (k ? P.accentBelowAA.onSurfaces : 4.5), "link in \(mode): \(link)")
        }
    }

    @Test func speakerDiscsCarryTheirInitialsAndStandOutFromBothSurfaces() {
        for (mode, k) in Self.modes {
            for (i, pair) in (P.speakers + [P.unknownSpeaker]).enumerated() {
                let disc = pair.resolved(dark: k)
                #expect(P.contrast(P.speakerInitials.resolved(dark: k), disc) >= 4.5, "initials on disc \(i) in \(mode)")
                #expect(P.contrast(disc, P.surface.resolved(dark: k)) >= 3, "disc \(i) against the surface in \(mode)")
                #expect(P.contrast(disc, P.canvas.resolved(dark: k)) >= 3, "disc \(i) against the canvas in \(mode)")
            }
        }
    }

    @Test func statusColoursStayDistinctHues() {
        // Green, orange and red must not collapse into one another (meaning is carried by hue plus icon).
        for (_, k) in Self.modes {
            let ok = P.ok.resolved(dark: k), attention = P.attention.resolved(dark: k), failed = P.failed.resolved(dark: k)
            #expect(ok.g > ok.r && attention.r > attention.b && failed.r > failed.g)
            #expect(attention.g > failed.g, "orange is yellower than red")
        }
    }

    /// The handoff's measured pairs (docs/design-handoff/Design/contrast-report.json) plus the pairs the app adds:
    /// text and metadata on the selected sidebar row, and status colours on their own tinted strips.
    /// Exception (T74): the dark accent's text pairs are held to `AppPalette.accentBelowAA` instead of 4.5:1, on purpose.
    @Test func brandPairsMeetTheirMinimums() {
        for (mode, k) in Self.modes {
            func check(_ fg: P.Pair, _ bg: P.Pair, _ minimum: Double, _ what: String) {
                let c = P.contrast(fg.resolved(dark: k), bg.resolved(dark: k))
                #expect(c >= minimum, "\(what) in \(mode): \(c)")
            }
            let accentText = k ? P.accentBelowAA.onSurfaces : 4.5
            for bg in [("surface", P.surface), ("canvas", P.canvas)] {
                for fg in [("text", P.text), ("secondary", P.secondaryText), ("sage", P.sage), ("warning", P.warning), ("danger", P.danger)] {
                    check(fg.1, bg.1, 4.5, "\(fg.0) on \(bg.0)")
                }
                check(P.accent, bg.1, accentText, "accent on \(bg.0)")
                check(P.controlBorder, bg.1, 3, "control border on \(bg.0)")
            }
            check(P.onAccent, P.accent, accentText, "on-accent label on accent")
            check(P.text, P.selection, 4.5, "text on selected row")
            // The selected row draws its metadata in the text colour: secondary text is 4.39:1 on Selection in light.
            // The accent edge and links on the jumped-to transcript line: 2.5:1 in dark (T74 exception).
            check(P.accent, P.selection, k ? P.accentBelowAA.onSelection : 4.5, "accent on Selection")
            // The selected row's status glyph and the jumped-to transcript line's flags.
            for fg in [("sage", P.sage), ("warning", P.warning), ("danger", P.danger)] {
                check(fg.1, P.selection, 4.5, "\(fg.0) on Selection")
            }
        }
    }

    /// T74: the exception stays narrow: the dark accent sits just above its floors (so a lighter step would be noticed)
    /// and light mode keeps AA.
    @Test func darkAccentExceptionIsDocumentedAndTight() {
        let surface = P.contrast(P.accent.dark, P.surface.dark), onAccent = P.contrast(P.onAccent.dark, P.accent.dark)
        #expect(surface < 4.5 && surface >= P.accentBelowAA.onSurfaces, "accent on Forest surface: \(surface)")
        #expect(onAccent < 4.5 && onAccent >= P.accentBelowAA.onSurfaces, "cream on accent: \(onAccent)")
        #expect(P.contrast(P.onAccent.dark, P.accent.dark) > P.contrast(P.surface.dark, P.accent.dark), "cream reads better than forest")
        #expect(P.contrast(P.accent.light, P.surface.light) >= 4.5)
    }

    /// The asset catalog the app draws with holds exactly these values in both appearances.
    @Test func assetCatalogMatchesThePalette() throws {
        let catalog = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../App/Resources/Assets.xcassets")
        for (name, pair) in P.named {
            let data = try Data(contentsOf: catalog.appending(path: "\(name).colorset/Contents.json"))
            let colors = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["colors"] as? [[String: Any]])
            for entry in colors {
                let dark = (entry["appearances"] as? [[String: String]])?.contains { $0["value"] == "dark" } ?? false
                let c = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
                func byte(_ k: String) -> UInt8 { UInt8((Double(c[k] ?? "") ?? -1) * 255 + 0.5) }
                let rgb = P.RGB(UInt32(byte("red")) << 16 | UInt32(byte("green")) << 8 | UInt32(byte("blue")))
                #expect(rgb == pair.resolved(dark: dark), "\(name) \(dark ? "dark" : "light")")
            }
            #expect(colors.count == 2, "\(name) has a light and a dark value")
        }
    }

    @Test func contrastMathMatchesWCAGReferencePoints() {
        #expect(abs(P.contrast(P.RGB(0x000000), P.RGB(0xFFFFFF)) - 21) < 0.001)
        #expect(abs(P.contrast(P.RGB(0x777777), P.RGB(0xFFFFFF)) - 4.48) < 0.01)
        #expect(P.over(P.RGB(0xFF0000), 0.5, P.RGB(0x000000)) == P.RGB(0x800000))
    }

    @Test func appearanceSettingRoundTripsAndToggleFlips() {
        for a in AppAppearance.allCases { #expect(AppAppearance(stored: a.rawValue) == a) }
        #expect(AppAppearance(stored: nil) == .system)
        #expect(AppAppearance(stored: "sepia") == .system)
        #expect(AppAppearance.key == "appearance")
        #expect(AppAppearance.toggled(effectiveIsDark: true) == .light)
        #expect(AppAppearance.toggled(effectiveIsDark: false) == .dark)
        #expect(AppAppearance.allCases.map(\.title) == ["Match system", "Light", "Dark"])
        #expect(AppAppearance.toggleHelp(effectiveIsDark: true) == "Switch to light mode (⌘⇧L)")
        #expect(AppAppearance.toggleHelp(effectiveIsDark: false) == "Switch to dark mode (⌘⇧L)")
        #expect(AppAppearance.toggleMenuTitle(effectiveIsDark: false) == "Switch to Dark Mode")
    }
}
