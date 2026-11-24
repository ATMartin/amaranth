import Testing
@testable import Presentation

@Suite("Text size setting")
struct TextSizeTests {
    @Test func storedValuesRoundTripAndUnknownReadsAsDefault() {
        for s in TextSize.allCases { #expect(TextSize(stored: s.rawValue) == s) }
        #expect(TextSize(stored: nil) == .default)
        #expect(TextSize(stored: "huge") == .default)
        #expect(TextSize.key == "textSize", "persisted under the key named in T36")
    }

    @Test func scalesAreOrderedAroundOne() {
        #expect(TextSize.smaller.scale < TextSize.default.scale && TextSize.default.scale < TextSize.larger.scale)
        #expect(TextSize.default.scale == 1)
        #expect(TextSize.allCases.map(\.title) == ["Smaller", "Default", "Larger"])
    }
}
