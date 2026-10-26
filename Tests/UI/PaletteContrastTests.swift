import Testing
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
            #expect(link >= 4.5, "link in \(mode): \(link)")
        }
    }

    @Test func speakerDiscsCarryWhiteInitialsAndStandOutFromTheWindow() {
        let white = P.RGB(0xFFFFFF)
        for (mode, k) in Self.modes {
            for (i, pair) in (P.speakers + [P.unknownSpeaker]).enumerated() {
                let disc = pair.resolved(dark: k)
                #expect(P.contrast(white, disc) >= 4.5, "initials on disc \(i) in \(mode)")
                #expect(P.contrast(disc, P.windowBackground.resolved(dark: k)) >= 3, "disc \(i) against the window in \(mode)")
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
