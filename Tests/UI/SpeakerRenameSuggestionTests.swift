import Testing
import Foundation
import Domain
@testable import Presentation

@Suite("Speaker-rename suggestions (T60)")
struct SpeakerRenameSuggestionTests {
    @Test func suggestsPeopleWithoutTheCurrentName() {
        let people = [Person(name: "Dana Whitfield", source: .calendar), Person(name: "Ravi Patel"), Person(name: "dana whitfield")]
        let named = Speaker(id: SpeakerID("s1"), label: "Speaker 1", displayName: "Dana Whitfield")
        #expect(SpeakerMenu.renameSuggestions(people, for: named) == ["Ravi Patel"])
        #expect(SpeakerMenu.renameSuggestions(people, for: Speaker(id: SpeakerID("s2"), label: "Speaker 2")) == ["Dana Whitfield", "Ravi Patel"])
        #expect(SpeakerMenu.renameSuggestions([], for: named).isEmpty)
    }

    /// Choosing a suggestion fills the field and saves through the same `EditComposer.rename` as typing.
    @Test func suggestionMakesTheSameEditAsTyping() {
        let t = TranscriptRevision(meetingID: MeetingID("m"), kind: .final, stage: .attributed, createdAt: Date(),
                                   producer: ProducerInfo(component: "t", configHash: "t"), segments: [], coverage: [],
                                   speakers: [Speaker(id: SpeakerID("s1"), label: "Speaker 1")])
        let composer = EditComposer(meetingID: MeetingID("m"), revision: t, existing: [])
        let picked = SpeakerMenu.renameSuggestions([Person(name: "Ravi Patel", source: .calendar)], for: t.speakers[0])[0]
        let chosen = composer.rename(SpeakerID("s1"), to: picked), typed = composer.rename(SpeakerID("s1"), to: "Ravi Patel ")
        #expect(chosen.operation == typed.operation && chosen.operation == .renameSpeaker(SpeakerID("s1"), displayName: "Ravi Patel"))
        #expect(chosen.baseRevisionID == typed.baseRevisionID && chosen.sequence == typed.sequence)
    }
}
