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
        saves.schedule("other") { now in calls.append(("other", now)) }
        saves.cancel("other")
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.count == 1 && calls[0] == ("notes", false) && !saves.hasPending)
    }
}
