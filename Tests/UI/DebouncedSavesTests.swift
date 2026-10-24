import Testing
@testable import Presentation

@Suite("Notes editor saves")
@MainActor struct DebouncedSavesTests {
    /// T24: typing then collapsing (or switching meeting) within the debounce window still saves, exactly once.
    @Test func flushWithinTheWindowSavesOnceImmediately() async throws {
        let saves = DebouncedSaves(delay: .milliseconds(200))
        var calls: [(String, Bool)] = []
        saves.schedule("notes") { now in calls.append(("first", now)) }
        saves.schedule("notes") { now in calls.append(("latest", now)) }   // a newer edit replaces the pending one
        saves.flush()
        #expect(calls.count == 1 && calls[0] == ("latest", true) && !saves.hasPending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.count == 1, "the cancelled timer must not save again")
    }

    @Test func savesAfterTheDelayAndFieldsAreIndependent() async throws {
        let saves = DebouncedSaves(delay: .milliseconds(100))
        var calls: [(String, Bool)] = []
        saves.schedule("notes") { now in calls.append(("notes", now)) }
        saves.schedule("scratchpad") { now in calls.append(("scratchpad", now)) }
        saves.cancel("scratchpad")
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.count == 1 && calls[0] == ("notes", false) && !saves.hasPending)
    }

    @Test func collapsedHintCountsWords() {
        #expect(CollapsedEditorHint.text(for: "") == nil && CollapsedEditorHint.text(for: "  \n ") == nil)
        #expect(CollapsedEditorHint.text(for: "call") == "1 word")
        #expect(CollapsedEditorHint.text(for: "call the\nvendor today") == "4 words")
    }
}
