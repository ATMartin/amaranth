import Testing
import Domain
@testable import Presentation

@Suite("Default tab rules")
struct DetailTabRulesTests {
    @Test func recordingOrPendingTranscriptShowsTranscript() {
        #expect(DetailTabRules.defaultTab(isRecording: true, hasFinalTranscript: false, hasSummary: false) == .transcript)
        #expect(DetailTabRules.defaultTab(isRecording: true, hasFinalTranscript: true, hasSummary: true) == .transcript)
        #expect(DetailTabRules.defaultTab(isRecording: false, hasFinalTranscript: false, hasSummary: false) == .transcript)
    }

    @Test func notesShowOnceTheyExist() {
        #expect(DetailTabRules.defaultTab(isRecording: false, hasFinalTranscript: true, hasSummary: true) == .notes)
    }

    /// Final transcript without notes, which is also the state when no notes model is installed.
    @Test func finalTranscriptWithoutNotesShowsTranscript() {
        #expect(DetailTabRules.defaultTab(isRecording: false, hasFinalTranscript: true, hasSummary: false) == .transcript)
    }

    @Test func switchesToNotesOnceWhenNotesArrive() {
        let m = MeetingID("m1")
        var s = NotesArrivalSwitch()
        s.stopped(m, notesModelReady: true)
        let r1 = s.shouldSwitchToNotes(viewing: m, hasSummary: false)
        #expect(!r1)
        let r2 = s.shouldSwitchToNotes(viewing: m, hasSummary: true)
        #expect(r2)
        let r3 = s.shouldSwitchToNotes(viewing: m, hasSummary: true)
        #expect(!r3)   // only once
    }

    @Test func neverFightsTheUser() {
        let m = MeetingID("m1")
        var s = NotesArrivalSwitch()
        s.stopped(m, notesModelReady: true)
        s.userChoseTab(m)
        let r4 = s.shouldSwitchToNotes(viewing: m, hasSummary: true)
        #expect(!r4)
    }

    @Test func neverSwitchesWithoutNotesModelOrForOtherMeetings() {
        let m = MeetingID("m1"), other = MeetingID("m2")
        var s = NotesArrivalSwitch()
        s.stopped(m, notesModelReady: false)
        let r5 = s.shouldSwitchToNotes(viewing: m, hasSummary: true)
        #expect(!r5)
        s.stopped(m, notesModelReady: true)
        let r6 = s.shouldSwitchToNotes(viewing: other, hasSummary: true)
        #expect(!r6)
        #expect(s.isWaiting(m))
    }
}
