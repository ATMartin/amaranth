import Foundation
import Testing
import Contextual
import Domain
import Presentation
import Storage

/// T115: how evidence becomes the answer request, guidance, notes and guards.
@Suite("Contextual Ask composition (T115)")
struct ContextualAskTests {
    static let tz = TimeZone(identifier: "America/New_York")!
    func passage(_ title: String, _ day: Double, _ text: String, rank: Int) -> RankedPassage {
        let line = Passage.Line(segmentID: TranscriptSegmentID("\(title)-\(rank)"), start: .seconds(10), speaker: "Speaker 1", text: text, matched: true)
        return RankedPassage(passage: Passage(meetingID: MeetingID(title), meetingTitle: title, meetingDate: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400),
                                              source: .transcript, ref: "r\(rank)", lines: [line], evidence: [], score: 1), rank: rank, askedSpeakerLines: 0)
    }
    func evidence(_ ps: [RankedPassage], people: [ResolvedPerson] = [], range: MeetingDateRange? = nil, coverage: IndexCoverage? = nil, semantic: Bool = true) -> ContextualEvidence {
        ContextualEvidence(passages: ps, plan: QueryPlan(), planFallback: false, constraints: ResolvedConstraints(dateRange: range, people: people),
                           coverage: coverage ?? IndexCoverage(meetingsInScope: 2, meetingsIndexed: 2, chunks: 4, chunksEmbedded: 4, encoderAvailable: true),
                           semantic: semantic, generations: [:], timings: [:], scopeMeetings: 2)
    }
    let req = ContextualRequest(question: "What did I promise today?", scope: .all, requestTime: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/New_York")

    @Test func passagesGoInDateOrderWithRanksAndCitationsMapToThem() {
        let e = evidence([passage("Late", 3, "we reopened it", rank: 0), passage("Early", 1, "we decided X", rank: 1)])
        guard case .answer(let r, let ps) = ContextualAsk.compose(e, request: req, requestID: "x") else { Issue.record("expected answer"); return }
        #expect(ps.map(\.meetingTitle) == ["Early", "Late"])
        #expect(r.passages.map(\.rank) == [1, 0])
    }

    @Test func ambiguousSpeakerClarifiesAndEmptyEvidenceIsHonest() {
        let amb = evidence([passage("A", 1, "x", rank: 0)], people: [ResolvedPerson(name: "Andrew", role: .speaker, resolution: .ambiguous, speakerNames: ["Andrew", "Andrew Kim"])])
        guard case .clarify(let t) = ContextualAsk.compose(amb, request: req, requestID: "x") else { Issue.record("expected clarify"); return }
        #expect(t.contains("“Andrew” and “Andrew Kim”"))
        guard case .noEvidence = ContextualAsk.compose(evidence([]), request: req, requestID: "x") else { Issue.record("expected no evidence"); return }
    }

    @Test func unmappedUserIsNeverTheSubject() {
        let c = ResolvedConstraints(people: [ResolvedPerson(name: "I", role: .selfUser, resolution: .selfUnmapped)])
        #expect(ContextualAsk.modelQuestion("What did I promise during my calls today? I'll check.", c) == "What did each speaker promise during the calls today? each speaker will check.")
        let mapped = ResolvedConstraints(people: [ResolvedPerson(name: "I", role: .selfUser, resolution: .selfMapped, speakerNames: ["Me"])])
        #expect(ContextualAsk.modelQuestion("What did I promise?", mapped) == "What did Me (the user) promise?")
        #expect(ContextualAsk.attributionViolation("I promised to send the deck by Friday.", c) != nil)
        #expect(ContextualAsk.attributionViolation("You committed to the review.", c) != nil)
        #expect(ContextualAsk.attributionViolation("Speaker 2 said they would send the deck; I can't tell which speaker is you.", c) == nil)
        #expect(ContextualAsk.attributionViolation("I promised it.", mapped) == nil, "mapped: the model may speak about the user's speaker")
    }

    @Test func guidanceAndNotesStateWhatWasSearched() {
        let r = MeetingDateRange(start: ISO8601DateFormatter().date(from: "2026-10-26T00:00:00-04:00")!, end: ISO8601DateFormatter().date(from: "2026-11-02T00:00:00-05:00")!,
                                 kind: .calendarWeek, phrase: "last week")
        let e = evidence([passage("A", 1, "x", rank: 0)], people: [ResolvedPerson(name: "Rosa", role: .speaker, resolution: .mentionedOnly)], range: r,
                         coverage: IndexCoverage(meetingsInScope: 10, meetingsIndexed: 4, chunks: 40, chunksEmbedded: 16, encoderAvailable: true))
        let g = ContextualAsk.guidance(e, timeZone: Self.tz)
        #expect(g.contains { $0.contains("Mon, Oct 26 to Sun, Nov 1") || $0.contains("Oct 26") })
        #expect(g.contains { $0.contains("Rosa is not a named speaker") })
        let n = ContextualAsk.notes(e, timeZone: Self.tz)
        #expect(n.contains { $0.contains("4 of 10 meetings") })
        #expect(n.contains { $0.contains("Rosa isn't a named speaker") })
        #expect(ContextualAsk.notes(evidence([], coverage: IndexCoverage(meetingsInScope: 1, meetingsIndexed: 0, chunks: 1, chunksEmbedded: 0, encoderAvailable: false), semantic: false), timeZone: Self.tz)
            .contains { $0.contains("needs the search model") })
    }
}
