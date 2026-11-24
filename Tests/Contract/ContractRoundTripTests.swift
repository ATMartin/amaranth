import Foundation
import Testing
import Domain
import DomainFixtures

@Suite("Contract round trips")
struct ContractRoundTripTests {
    func roundTrip<T: Codable & Sendable & Equatable>(_ value: T) throws -> T {
        let data = try ContractCoding.encode(value)
        let back = try ContractCoding.decode(T.self, from: data)
        #expect(back == value)
        return back
    }

    @Test("Every fixture meeting round-trips losslessly", arguments: Fixtures.all)
    func fixtureRoundTrip(_ fixture: FixtureMeeting) throws {
        _ = try roundTrip(fixture)
    }

    @Test func preservesSourceAndOverlappingIntervals() throws {
        let f = Fixtures.twoSourceConversation
        let t = try roundTrip(f.transcript!)
        let overlapSeg = try #require(t.segment(TranscriptSegmentID("g2")))
        #expect(overlapSeg.source == .systemOutput)
        #expect(overlapSeg.flags.contains(.overlap))
        #expect(overlapSeg.speaker == .multiple([SpeakerID("spk-2"), SpeakerID("spk-3")]))
        // Overlap with the preceding segment's interval is preserved, not clipped.
        let prev = try #require(t.segment(TranscriptSegmentID("g1")))
        #expect(prev.interval.overlaps(overlapSeg.interval))
        let d = try roundTrip(f.diarization[0])
        #expect(d.overlaps == [.seconds(9, 12)])
    }

    @Test func preservesUnknownSpeakers() throws {
        let t = try roundTrip(Fixtures.twoSourceConversation.transcript!)
        let ack = try #require(t.segment(TranscriptSegmentID("g4")))
        #expect(ack.speaker == .unknown)
        #expect(ack.words.allSatisfy { $0.speaker == .unknown })
    }

    @Test func preservesNullOwnersAndEvidence() throws {
        let s = try roundTrip(Fixtures.twoSourceConversation.summary!)
        let a1 = try #require(s.content.actionItems.first { $0.id == SummaryItemID("n-a1") })
        #expect(a1.owner == nil)
        #expect(!a1.evidence.isEmpty)
        let a2 = try #require(s.content.actionItems.first { $0.id == SummaryItemID("n-a2") })
        #expect(a2.owner == "Dana")
        #expect(a2.due?.originalText == "by Wednesday")
        #expect(a2.due?.normalized == nil, "relative date text kept verbatim without guessing")
        // Null owner must encode as an absent/null value, never as an empty string.
        let json = String(decoding: try ContractCoding.encode(a1), as: UTF8.self)
        #expect(!json.contains("\"owner\":\"\""))
    }

    @Test func evidenceKindsStayDistinct() throws {
        let rev = RevisionID("r")
        let spoken = EvidenceRef.transcript(.init(revisionID: rev, segmentID: .init("s"), firstWord: .init("a"), lastWord: .init("b")))
        let note = EvidenceRef.personalNote(.init(revisionID: RevisionID("p"), start: 0, end: 4))
        #expect(try roundTrip(spoken).isSpoken)
        #expect(try !roundTrip(note).isSpoken)
    }

    @Test func provisionalAndFinalRevisionsAreDistinct() throws {
        var t = Fixtures.twoSourceConversation.transcript!
        t.kind = .provisional
        #expect(try roundTrip(t).kind == .provisional)
    }

    @Test func sessionTimeIsIntegerNanoseconds() throws {
        let t = SessionTime(nanoseconds: 7_200_000_000_123)
        let json = String(decoding: try ContractCoding.encoder().encode(t), as: UTF8.self)
        #expect(json == "7200000000123")
    }

    @Test func rejectsNewerContractVersion() throws {
        let data = Data(#"{"contractVersion": 999, "payload": 1}"#.utf8)
        #expect(throws: DomainError.unsupportedContractVersion(found: 999, supported: ContractVersion.current)) {
            _ = try ContractCoding.decode(Int.self, from: data)
        }
    }

    @Test func rejectsInvertedIntervalOnDecode() throws {
        let data = Data(#"{"contractVersion": 1, "payload": {"start": 10, "end": 5}}"#.utf8)
        #expect(throws: DomainError.self) { _ = try ContractCoding.decode(SessionInterval.self, from: data) }
    }

    @Test func workerMessagesRoundTripAndAreBounded() throws {
        let job = JobDescriptor(jobID: JobID("j"), key: JobKey(meetingID: MeetingID("m"), stage: .transcribe, inputHash: "i", configHash: "c"),
                                workDirectory: URL(filePath: "/tmp/x"))
        for req in [WorkerRequest.ping, .run(job), .injectFault(.crash)] {
            let back = try WorkerIPCCodec.decode(WorkerRequest.self, from: WorkerIPCCodec.encode(req))
            #expect(back == req)
        }
        let huge = String(repeating: "x", count: WorkerIPCLimits.maxMessageBytes + 1)
        #expect(throws: DomainError.self) { _ = try WorkerIPCCodec.encode(huge) }
    }
}
