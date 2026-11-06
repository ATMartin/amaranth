import Foundation
import Testing
import Contextual
@testable import Storage
import Domain
import DomainFixtures

/// T114: scope and dates apply before candidates; nothing deleted/out of scope leaks; fallbacks are labeled.
@Suite("Contextual retriever (T114)", .serialized)
struct ContextualRetrieverTests {
    final class Models: ContextualModels, @unchecked Sendable {
        var planDelay: Double = 0
        var plan = QueryPlan()
        func plan(requestID: String, question: String, history: [AnswerTurn]) async throws -> PlanResponse {
            if planDelay > 0 { try await Task.sleep(for: .seconds(planDelay)) }
            return PlanResponse(plan: plan.validated(question: question), fallback: false, seconds: planDelay, generatedTokens: 0)
        }
        func embedQueries(requestID: String, texts: [String]) async throws -> EmbedResponse {
            EmbedResponse(producer: FakeEncoder.producer, vectors: EmbedResponse.pack(texts.map(FakeEncoder.vector)), seconds: 0, loaded: false)
        }
        func cancel(requestID: String) {}
    }

    static let tz = "America/New_York"
    static let now = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00-05:00")!

    struct Lib {
        let store: MeetingStore
        func meeting(_ title: String, _ lines: [(String?, String)], start: String, folder: FolderID? = nil) throws -> MeetingID {
            let m = MeetingID()
            let d = ISO8601DateFormatter().date(from: start)!
            try store.upsertMeeting(Meeting(id: m, title: title, createdAt: d, clock: SessionClock(utcOrigin: d, timeZoneIdentifier: ContextualRetrieverTests.tz, hostTimeOriginNanos: 0),
                                            captureState: .captured, duration: .seconds(60), folderID: folder))
            let names = Array(Set(lines.compactMap(\.0))).sorted()
            let speakers = [Speaker(id: SpeakerID("\(m.rawValue)-anon"), label: "Speaker 1")] + names.enumerated().map { Speaker(id: SpeakerID("\(m.rawValue)-\($0.offset)"), label: "Speaker \($0.offset + 2)", displayName: $0.element) }
            let segs = lines.enumerated().map { i, l in
                let who = SpeakerAssignment.speaker(l.0.flatMap { n in speakers.first { $0.displayName == n }?.id } ?? speakers[0].id)
                let words = l.1.split(separator: " ").enumerated().map { j, w in
                    Word(id: WordID("\(m.rawValue)-\(i)-\(j)"), text: String(w), interval: .seconds(Double(i) * 5 + Double(j) * 0.2, Double(i) * 5 + Double(j) * 0.2 + 0.1), source: .systemOutput, speaker: who)
                }
                return TranscriptSegment(id: TranscriptSegmentID("\(m.rawValue)-s\(i)"), source: .systemOutput, interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end), words: words, speaker: who)
            }
            try store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: d, producer: ProducerInfo(component: "t", configHash: "t"),
                                                           segments: segs, coverage: [], speakers: speakers))
            return m
        }
        func embedAll(except: Set<MeetingID> = []) throws {
            let p = try store.pendingContextChunks(producer: FakeEncoder.producer.id, limit: 10_000, excluding: except)
            try store.publishContextVectors(p.map { ($0.contentHash, FakeEncoder.vector($0.text)) }, producer: FakeEncoder.producer)
        }
    }

    func lib() throws -> Lib { Lib(store: try MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: "amr-ctxret-\(UUID())"))) }

    func ask(_ l: Lib, _ q: String, scope: ContextualRequest.Scope = .all, history: [AnswerTurn] = [], models: Models = Models(), producer: EncoderProducer? = FakeEncoder.producer,
             learnsProducer: Bool = false, planBudget: Double = 4.5) async throws -> ContextualEvidence {
        try await ContextualRetriever(store: l.store, models: models, producer: producer, learnsProducer: learnsProducer)
            .retrieve(ContextualRequest(question: q, scope: scope, requestTime: Self.now, timeZoneIdentifier: Self.tz, history: history),
                      previous: nil, requestID: UUID().uuidString, planDeadline: Date().addingTimeInterval(planBudget))
    }

    @Test func meetingDatesFilterBeforeCandidates() async throws {
        let l = try lib()
        let inWeek = try l.meeting("Sync", [(nil, "Dana could pick up the Kestrel cutover after Northgate wraps")], start: "2026-10-28T10:00:00-04:00")
        let early = try l.meeting("Sync", [(nil, "Dana could pick up the Kestrel cutover after Northgate wraps")], start: "2026-10-20T10:00:00-04:00")
        try l.embedAll()
        let e = try await ask(l, "Who could pick up the Kestrel cutover last week?")
        #expect(e.constraints.dateRange?.kind == .calendarWeek)
        #expect(Set(e.passages.map(\.passage.meetingID)) == [inWeek])
        #expect(!e.passages.contains { $0.passage.meetingID == early })
        #expect(e.scopeMeetings == 1)
    }

    @Test func uiScopeAndDeletionNeverLeak() async throws {
        let l = try lib()
        let folder = try l.store.createFolder(name: "Clients").id
        let a = try l.meeting("Client call", [(nil, "the renewal price is forty thousand")], start: "2026-11-02T10:00:00-05:00", folder: folder)
        let b = try l.meeting("Internal", [(nil, "the renewal price is forty thousand")], start: "2026-11-03T10:00:00-05:00")
        let gone = try l.meeting("Deleted", [(nil, "the renewal price is forty thousand")], start: "2026-11-04T10:00:00-05:00")
        try l.embedAll()
        try l.store.tombstone(gone)
        #expect(Set(try await ask(l, "what is the renewal price", scope: .folder(folder)).passages.map(\.passage.meetingID)) == [a])
        #expect(Set(try await ask(l, "what is the renewal price", scope: .meeting(b)).passages.map(\.passage.meetingID)) == [b])
        let all = try await ask(l, "what is the renewal price")
        #expect(!all.passages.contains { $0.passage.meetingID == gone })
        #expect(all.generations[gone] == nil)
    }

    @Test func editedTextIsNeverReturnedAndCitationsAreCurrent() async throws {
        let l = try lib()
        let m = try l.meeting("Pricing", [(nil, "we will charge nineteen dollars for the starter plan"), (nil, "the secret acquisition is on hold")], start: "2026-11-02T10:00:00-05:00")
        try l.embedAll()
        let tr = try #require(try l.store.meeting(m)?.currentTranscriptRevisionID)
        try l.store.appendEdit(UserEdit(meetingID: m, baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                        operation: .deleteText(WordRange(revisionID: tr, first: WordID("\(m.rawValue)-1-0"), last: WordID("\(m.rawValue)-1-5")))))
        try l.store.appendEdit(UserEdit(meetingID: m, baseRevisionID: tr, sequence: 2, createdAt: Date(),
                                        operation: .correctText(WordRange(revisionID: tr, first: WordID("\(m.rawValue)-0-3"), last: WordID("\(m.rawValue)-0-3")), replacement: "twenty-nine")))
        let e = try await ask(l, "what is the price of the starter plan and the acquisition")
        let text = e.passages.flatMap { $0.passage.lines.map(\.text) }.joined(separator: " ")
        #expect(!text.contains("secret") && !text.contains("nineteen") && text.contains("twenty-nine"))
        #expect(e.passages.allSatisfy { !$0.passage.evidence.isEmpty })
    }

    @Test func unindexedMeetingsAreFoundByKeywordsAndCoverageSaysPartial() async throws {
        let l = try lib()
        let indexed = try l.meeting("A", [(nil, "the offsite budget is fifteen hundred euros")], start: "2026-11-02T10:00:00-05:00")
        let pending = try l.meeting("B", [(nil, "the Lisbon venue is booked near the river")], start: "2026-11-03T10:00:00-05:00")
        try l.embedAll(except: [pending])
        let e = try await ask(l, "where is the Lisbon venue")
        #expect(e.passages.contains { $0.passage.meetingID == pending })
        #expect(!e.coverage.complete && e.coverage.meetingsIndexed == 1)
        _ = indexed
        // Keyword only (no encoder): still answers from FTS, labeled not semantic.
        let k = try await ask(l, "where is the Lisbon venue", producer: nil)
        #expect(!k.semantic && k.passages.contains { $0.passage.meetingID == pending })
    }

    /// The app's Ask: no producer reported yet (the indexer hasn't embedded a batch this launch) still searches by
    /// meaning with the encoder that embedded the question — never keyword-only.
    @Test func unknownProducerIsLearnedFromTheQuestionEmbedding() async throws {
        let l = try lib()
        let m = try l.meeting("Staffing", [(nil, "Dana could pick that up once her current work wraps")], start: "2026-11-02T10:00:00-05:00")
        try l.embedAll()
        let e = try await ask(l, "Dana could pick that up once her current work wraps", producer: nil, learnsProducer: true)
        #expect(e.semantic && e.coverage.complete)
        #expect(e.passages.contains { $0.passage.meetingID == m })
    }

    @Test func slowPlanningFallsBackWithinBudgetAndKeepsConstraints() async throws {
        let l = try lib()
        _ = try l.meeting("Sync", [(nil, "Andrew wants to move into management next year")], start: "2026-10-28T10:00:00-04:00")
        try l.embedAll()
        let slow = Models(); slow.planDelay = 3
        let t0 = ContinuousClock.now
        let e = try await ask(l, "What did Andrew propose last week?", models: slow, planBudget: 0.3)
        #expect(ContinuousClock.now - t0 < .seconds(2))
        #expect(e.planFallback && e.constraints.dateRange?.kind == .calendarWeek, "the date constraint comes from the question, not the model")
        #expect(e.constraints.people.contains { $0.name == "Andrew" })
        #expect(!e.passages.isEmpty)
    }

    @Test func followUpKeepsItsSubjectAndAskedSpeakerLinesRankFirst() async throws {
        let l = try lib()
        _ = try l.meeting("Staffing", [("Andrew", "I would like to lead the platform team next year"), (nil, "the cafeteria menu changes on Monday"),
                                        (nil, "Priya said Andrew should lead the platform team")], start: "2026-11-02T10:00:00-05:00")
        _ = try l.meeting("Other", [(nil, "lunch options near the office were discussed at length today")], start: "2026-11-03T10:00:00-05:00")
        try l.embedAll()
        let m = Models(); m.plan = QueryPlan(people: [.init(name: "Andrew", role: .speaker)])
        let e = try await ask(l, "What did Andrew propose?", models: m)
        #expect(e.constraints.people.first?.resolution == .speaker)
        #expect(e.passages.sorted { $0.rank < $1.rank }.first?.askedSpeakerLines ?? 0 > 0)
        let f = try await ask(l, "and when would that start?", history: [AnswerTurn(question: "What did Andrew propose about leading the platform team?", answer: "He wants to lead it.")])
        #expect(f.passages.first?.passage.meetingTitle == "Staffing")
    }
}
