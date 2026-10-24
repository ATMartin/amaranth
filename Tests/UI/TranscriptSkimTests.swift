import Testing
import Domain
import DomainFixtures
@testable import Presentation

@Suite("Transcript skim mode")
struct TranscriptSkimTests {
    static func speech(_ id: String, _ a: Double) -> TranscriptRow {
        TranscriptRow(id: id, kind: .speech, start: .seconds(a), end: .seconds(a + 2), source: .systemOutput, assignment: .unknown,
                      speakerLabel: "Speaker 1", text: "words \(id)", range: nil, segmentID: TranscriptSegmentID(id), flags: [.overlap])
    }
    static func gap(_ id: String, _ a: Double, _ b: Double, _ reason: String = "Speech here could not be transcribed") -> TranscriptRow {
        TranscriptRow(id: id, kind: .gap(reason: reason), start: .seconds(a), end: .seconds(b), source: .systemOutput, assignment: .unknown,
                      speakerLabel: "", text: "", range: nil, segmentID: nil, flags: [])
    }

    @Test func consecutiveGapsCollapseAndSpeechRowsAreUnchanged() {
        let rows = [Self.speech("s1", 0), Self.gap("g1", 2, 4), Self.gap("g2", 4, 9, "Audio was not recorded"), Self.gap("g3", 9, 10),
                    Self.speech("s2", 10), Self.gap("g4", 12, 13), Self.speech("s3", 13)]
        let skim = TranscriptRows.skim(rows)
        #expect(skim.map(\.id) == ["s1", "g1", "s2", "g4", "s3"], "the first gap of a run keeps its id; nothing else moves")
        #expect(skim.filter { !$0.isGap } == rows.filter { !$0.isGap }, "speech rows identical, flags included")
        let merged = skim[1]
        #expect(merged.start == .seconds(2) && merged.end == .seconds(10), "the merged gap covers the whole run")
        #expect(merged.kind == .gap(reason: "Speech here could not be transcribed; Audio was not recorded"), "each reason once")
        #expect(TranscriptRows.gapDescription(merged) == "No transcript 00:02–00:10: Speech here could not be transcribed; Audio was not recorded")
        #expect(TranscriptRows.skim([]) == [] && TranscriptRows.skim([Self.speech("a", 0)]) == [Self.speech("a", 0)])
    }

    /// Evidence jumps resolve against `detail.rows`; every speech row id must exist in the skim list too, and every gap
    /// must still be covered by some skim gap (VoiceOver announces it).
    @Test(arguments: Fixtures.all.map(\.name))
    func fixtureSpeechRowsAndGapsSurviveSkimMode(_ name: String) throws {
        let f = try #require(Fixtures.all.first { $0.name == name })
        guard let t = f.transcript else { return }
        let rows = TranscriptRows.build(t, edits: f.edits)
        let skim = TranscriptRows.skim(rows)
        #expect(rows.filter { !$0.isGap } == skim.filter { !$0.isGap })
        for g in rows where g.isGap {
            #expect(skim.contains { $0.isGap && $0.start <= g.start && g.end <= $0.end }, "gap at \(g.start) still shown")
        }
    }
}
