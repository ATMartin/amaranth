import Testing
import Domain
import DomainFixtures
@testable import Presentation

@Suite("Speaker menu in the transcript (T38)")
struct SpeakerMenuTests {
    static func row(_ a: SpeakerAssignment) -> TranscriptRow {
        TranscriptRow(id: "r", kind: .speech, start: .seconds(0), end: .seconds(1), source: .systemOutput, assignment: a,
                      speakerLabel: "x", text: "t", range: nil, segmentID: nil, flags: [])
    }

    @Test func subjectsAndTargetsFollowTheRowsSpeakers() throws {
        let t = try #require(Fixtures.twoSourceConversation.transcript)
        let s = t.speakers
        try #require(s.count >= 3)
        #expect(SpeakerMenu.subjects(of: Self.row(.speaker(s[1].id)), in: s) == [s[1]])
        #expect(SpeakerMenu.subjects(of: Self.row(.multiple([s[2].id, s[0].id])), in: s) == [s[0], s[2]], "speaker-list order")
        #expect(SpeakerMenu.subjects(of: Self.row(.unknown), in: s).isEmpty)
        #expect(SpeakerMenu.mergeTargets(for: s[1], in: s) == s.filter { $0.id != s[1].id })
        #expect(SpeakerMenu.assignTargets(for: Self.row(.speaker(s[1].id)), in: s) == s.filter { $0.id != s[1].id })
        #expect(SpeakerMenu.assignTargets(for: Self.row(.unknown), in: s) == s)
    }

    /// The column menu and the SpeakerBar call the same composer with the same ids, so the edits match.
    @Test func columnAndBarProduceTheSameEdits() throws {
        let f = Fixtures.twoSourceConversation
        let t = try #require(f.transcript)
        let c = EditComposer(meetingID: f.meeting.id, revision: t, existing: f.edits)
        let row = try #require(TranscriptRows.build(t, edits: []).first { if case .speaker = $0.assignment { true } else { false } })
        let fromColumn = try #require(SpeakerMenu.subjects(of: row, in: t.speakers).first)
        let fromBar = try #require(t.speakers.first { $0.id == fromColumn.id })
        #expect(c.rename(fromColumn.id, to: "Dana").operation == c.rename(fromBar.id, to: "Dana").operation)
        let target = try #require(SpeakerMenu.mergeTargets(for: fromColumn, in: t.speakers).first)
        #expect(try c.merge([fromColumn.id], into: target.id).operation == .mergeSpeakers(sources: [fromBar.id], into: target.id))
    }
}
