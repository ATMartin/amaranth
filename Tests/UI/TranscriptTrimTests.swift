import Foundation
import Testing
@testable import Presentation
import Storage
import Domain
import DomainFixtures

/// T96: delete a transcript line; start or end the meeting at a line.
@Suite("Transcript: delete lines, start and end here")
struct TranscriptTrimTests {
    let f = Fixtures.twoSourceConversation

    func speech(_ rows: [TranscriptRow]) -> [TranscriptRow] { rows.filter { !$0.isGap } }

    @Test func deletingALineRemovesOnlyThatLine() throws {
        let t = try #require(f.transcript)
        let rows = speech(TranscriptRows.build(t, edits: []))
        try #require(rows.count >= 3)
        let c = EditComposer(meetingID: f.meeting.id, revision: t, existing: [])
        let del = try c.delete(rows[1])
        let after = speech(TranscriptRows.build(t, edits: [del]))
        #expect(after.map(\.id) == rows.filter { $0.id != rows[1].id }.map(\.id))
        #expect(after.map(\.text) == rows.filter { $0.id != rows[1].id }.map(\.text), "other lines unchanged")
        #expect(t.allWords.count == t.applyingTextEdits([del]).allWords.count + t.allWords.filter { w in
            rows[1].range.map { r in
                let ws = t.allWords; let a = ws.firstIndex { $0.id == r.first }!, b = ws.firstIndex { $0.id == r.last }!
                return ws[a...b].contains { $0.id == w.id }
            } ?? false
        }.count)
        #expect(throws: Never.self) { try t.applyingTextEdits([del]).validate() }
    }

    @Test func startAndEndHereKeepOnlyTheLinesBetween() throws {
        let t = try #require(f.transcript)
        let rows = speech(TranscriptRows.build(t, edits: []))
        try #require(rows.count >= 4)
        var c = EditComposer(meetingID: f.meeting.id, revision: t, existing: [])
        let start = try c.start(from: rows[1])
        c = EditComposer(meetingID: f.meeting.id, revision: t, existing: [start])
        let end = try c.end(at: rows[rows.count - 2])
        let shown = TranscriptRows.build(t, edits: [start, end])
        #expect(speech(shown).map(\.id) == rows[1...(rows.count - 2)].map(\.id))
        // Gap rows outside the kept part go too.
        for g in shown where g.isGap { #expect(g.start >= rows[1].start && g.end <= rows[rows.count - 2].end) }
        // A later, wider mark never brings lines back.
        let wider = try EditComposer(meetingID: f.meeting.id, revision: t, existing: [start, end]).start(from: rows[0])
        #expect(speech(TranscriptRows.build(t, edits: [start, end, wider])).map(\.id) == speech(shown).map(\.id))
        #expect(throws: Never.self) { try t.applyingTextEdits([start, end]).validate() }
    }

    @Test func searchAndStoredEditsFollowTheDeletion() throws {
        let (store, root) = try tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try persist(f, in: store)
        let t = try #require(f.transcript)
        let rows = speech(TranscriptRows.build(t, edits: f.edits))
        let target = try #require(rows.last)
        let others = rows.dropLast().map(\.text).joined(separator: " ")
        let word = try #require(target.text.split(separator: " ").map(String.init).first { w in w.count > 3 && !others.contains(w) })
        #expect(try store.search(word, in: f.meeting.id).contains { $0.kind == .transcript })
        try store.appendEdit(try EditComposer(meetingID: f.meeting.id, revision: t, existing: store.edits(f.meeting.id)).end(at: rows[rows.count - 2]))
        let hits = try store.search(word, in: f.meeting.id)   // notes stay as they are and may still match
        #expect(!hits.contains { $0.kind == .transcript }, "trimmed text is no longer searchable")
        let detail = try #require(try MeetingDetail.load(store, f.meeting.id))
        #expect(!speech(detail.rows).contains { $0.id == target.id })
        #expect(detail.displayTranscript?.allWords.contains { target.range?.last == $0.id } == false, "exports and Ask use the display transcript")
    }

    @Test func confirmationsSayWhatGoesAndThatItCannotBeUndone() throws {
        let t = try #require(f.transcript)
        let row = try #require(speech(TranscriptRows.build(t, edits: [])).first)
        let m = TranscriptTrim.message(.end, at: row, audioPresent: true)
        #expect(m.contains("transcript and audio after") && m.contains("cannot be undone") && m.contains("Notes stay"))
        #expect(!TranscriptTrim.message(.start, at: row, audioPresent: false).contains("audio"))
    }
}
