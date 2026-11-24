import Testing
@testable import Presentation

@Suite("Review preferences")
struct ReviewPreferencesTests {
    /// The key is persisted in users' defaults: renaming it would silently reset everyone's Details choice.
    @Test func detailsKeyAndDefaultArePinned() {
        #expect(ReviewPreferences.showDetailsKey == "reviewShowDetails")
        #expect(ReviewPreferences.showDetailsDefault == false)
    }
}
