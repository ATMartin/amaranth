import Testing
import Domain
@testable import Presentation

@Suite("Transcript speaker runs")
struct TranscriptRunsTests {
    static let dana = SpeakerID("dana"), lee = SpeakerID("lee")

    static func speech(_ id: String, _ a: Double, _ who: SpeakerAssignment, _ source: SourceKind = .systemOutput) -> TranscriptRow {
        TranscriptRow(id: id, kind: .speech, start: .seconds(a), end: .seconds(a + 2), source: source, assignment: who,
                      speakerLabel: "x", text: "words \(id)", range: nil, segmentID: TranscriptSegmentID(id), flags: [])
    }
    static func gap(_ id: String, _ a: Double) -> TranscriptRow {
        TranscriptRow(id: id, kind: .gap(reason: "Recording paused"), start: .seconds(a), end: .seconds(a + 2), source: .systemOutput,
                      assignment: .unknown, speakerLabel: "", text: "", range: nil, segmentID: nil, flags: [])
    }
    static func ids(_ runs: [TranscriptRows.Run]) -> [[String]] { runs.map { $0.rows.map(\.id) } }

    @Test func sameSpeakerRowsFormOneRunAndAChangeStartsANewOne() {
        let rows = [Self.speech("a", 0, .speaker(Self.dana)), Self.speech("b", 2, .speaker(Self.dana)), Self.speech("c", 4, .speaker(Self.lee)),
                    Self.speech("d", 6, .speaker(Self.dana))]
        let runs = TranscriptRows.runs(rows)
        #expect(Self.ids(runs) == [["a", "b"], ["c"], ["d"]])
        #expect(runs.map(\.assignment) == [.speaker(Self.dana), .speaker(Self.lee), .speaker(Self.dana)])
        #expect(TranscriptRows.runStarts(rows) == ["a", "c", "d"])
    }

    @Test func unknownRowsGroupWithEachOther() {
        let rows = [Self.speech("a", 0, .unknown), Self.speech("b", 2, .unknown), Self.speech("c", 4, .speaker(Self.dana))]
        #expect(Self.ids(TranscriptRows.runs(rows)) == [["a", "b"], ["c"]])
    }

    @Test func overlappingRowsGroupOnlyWithTheSameSpeakers() {
        let both = SpeakerAssignment.multiple([Self.dana, Self.lee])
        let rows = [Self.speech("a", 0, both), Self.speech("b", 2, both), Self.speech("c", 4, .multiple([Self.lee, Self.dana])),
                    Self.speech("d", 6, .multiple([Self.dana])), Self.speech("e", 8, .speaker(Self.dana))]
        #expect(Self.ids(TranscriptRows.runs(rows)) == [["a", "b", "c"], ["d"], ["e"]], "same set in any order groups; a different set does not")
    }

    @Test func gapsAndSourceChangesBreakARun() {
        let rows = [Self.speech("a", 0, .speaker(Self.dana)), Self.gap("g1", 2), Self.gap("g2", 4), Self.speech("b", 6, .speaker(Self.dana)),
                    Self.speech("c", 8, .speaker(Self.dana), .microphone)]
        let runs = TranscriptRows.runs(rows)
        #expect(Self.ids(runs) == [["a"], ["g1"], ["g2"], ["b"], ["c"]], "each gap is its own run; the speaker shows again after it")
        #expect(runs.map(\.isGap) == [false, true, true, false, false])
        #expect(TranscriptRows.runs([]).isEmpty)
    }

    @Test func everyRowBelongsToExactlyOneRunInOrder() {
        let rows = (0..<50).map { (i: Int) -> TranscriptRow in
            if i % 7 == 3 { return Self.gap("g\(i)", Double(i)) }
            let who: SpeakerAssignment = i % 5 < 2 ? .speaker(Self.dana) : .unknown
            return Self.speech("s\(i)", Double(i), who)
        }
        #expect(TranscriptRows.runs(rows).flatMap(\.rows) == rows)
    }

    @Test func speakerColourIsStableAndInPalette() {
        let i = TranscriptRows.paletteIndex(SpeakerID("0d4f1c2e-aaaa-bbbb-cccc-000000000001"))
        #expect(i == TranscriptRows.paletteIndex(SpeakerID("0d4f1c2e-aaaa-bbbb-cccc-000000000001")))
        let spread = Set((0..<64).map { TranscriptRows.paletteIndex(SpeakerID("speaker-\($0)")) })
        #expect(spread.allSatisfy { (0..<TranscriptRows.speakerPaletteCount).contains($0) })
        #expect(spread.count >= 6, "ids spread over the palette")
    }

    @Test func meetingColoursAreDistinctAndStable() {
        let ids = (0..<8).map { SpeakerID("speaker-\($0)") }
        let map = TranscriptRows.paletteIndices(ids)
        #expect(Set(map.values).count == 8, "eight speakers, eight colours")
        #expect(map == TranscriptRows.paletteIndices(ids))
        #expect(map[ids[0]] == TranscriptRows.paletteIndex(ids[0]), "the first speaker keeps its hash colour")
        let many = TranscriptRows.paletteIndices((0..<12).map { SpeakerID("s\($0)") })
        #expect(many.count == 12 && many.values.allSatisfy { (0..<TranscriptRows.speakerPaletteCount).contains($0) }, "more than 8 reuse colours")
    }

    @Test func initials() {
        #expect(TranscriptRows.initials("Dana Smith") == "DS")
        #expect(TranscriptRows.initials("Speaker 2") == "S2")
        #expect(TranscriptRows.initials("dana") == "D")
        #expect(TranscriptRows.initials("Mary-Kate O'Neil Jones") == "MK")
        #expect(TranscriptRows.initials("") == "")
    }
}
