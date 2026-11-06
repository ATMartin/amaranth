import Foundation
import Testing
import Domain

@Suite("Contextual search contracts (T109–T110)")
struct ChunkerTests {
    func lines(_ n: Int, words: Int = 10) -> [ChunkSourceLine] {
        (0..<n).map { i in
            let ws = (0..<words).map { "w\(i)x\($0)" }
            return ChunkSourceLine(segmentID: TranscriptSegmentID("s\(i)"), speaker: i % 2 == 0 ? "Speaker 1" : nil, words: ws,
                                   wordIDs: ws.indices.map { WordID("s\(i)-w\($0)") }, start: .seconds(Double(i)))
        }
    }

    @Test func everyLineIsCoveredInOrderWithOverlapAndBoundedSize() {
        let ls = lines(60)
        let cs = Chunker.chunks(ls)
        #expect(cs.count > 3)
        let covered = Set(cs.flatMap { $0.spans.map(\.segmentID) })
        #expect(covered == Set(ls.map(\.segmentID)))
        for (a, b) in zip(cs, cs.dropFirst()) { #expect(b.firstLine == a.lastLine, "one line of overlap") }
        for c in cs {
            #expect(ContextualLimits.estimatedTokens(words: c.spans.count * 10, lines: c.spans.count) <= ContextualLimits.chunkMaxTokens + 20)
            #expect(c.text.hasPrefix("Speaker 1: ") || c.text.hasPrefix("Unknown speaker: "))
        }
        #expect(cs.map(\.ordinal) == Array(cs.indices))
    }

    @Test func oversizedLineIsSplitNeverTruncated() {
        let long = lines(1, words: 700)
        let cs = Chunker.chunks(long)
        #expect(cs.count >= 4)
        let words = cs.flatMap { $0.text.split(separator: " ").dropFirst(2) }   // drop "Speaker 1:"
        #expect(words.count == 700 || Set(words).count == 700)
        #expect(cs.first?.spans.first?.firstWord == WordID("s0-w0"))
        #expect(cs.last?.spans.last?.lastWord == WordID("s0-w699"))
    }

    @Test func contentHashDependsOnTextAndVersionOnly() {
        let a = Chunker.chunks(lines(30)), b = Chunker.chunks(lines(30))
        #expect(a.map(\.contentHash) == b.map(\.contentHash))
        var changed = lines(30); changed[0].words[0] = "edited"
        let c = Chunker.chunks(changed)
        #expect(c[0].contentHash != a[0].contentHash)
        #expect(c.last?.contentHash == a.last?.contentHash, "unchanged chunks keep their identity (vector reuse)")
        #expect(Chunker.chunks(lines(30), version: "chunk-v0")[0].contentHash != a[0].contentHash)
    }

    @Test func planValidationClampsAndNeverInventsConstraints() {
        let q = "What did Andrew propose to me last week?"
        let plan = QueryPlan(semanticQueries: ["a", "b", "c", "d", q], literalTerms: Array(repeating: "x", count: 20) + ["Andrew"],
                             people: [.init(name: "Andrew", role: .speaker), .init(name: "Priya", role: .speaker), .init(name: "me", role: .selfUser)],
                             meetingTime: "yesterday", subquestions: ["1", "2", "3", "4"])
        let v = plan.validated(question: q)
        #expect(v.semanticQueries.count == ContextualLimits.maxSemanticQueries - 1)
        #expect(v.literalTerms == ["x", "Andrew"])
        #expect(v.people.map(\.name) == ["Andrew", "I"], "Priya isn't in the question")
        #expect(v.meetingTime == nil, "a time phrase that isn't in the question is dropped")
        #expect(QueryPlan(meetingTime: "Last Week").validated(question: q).meetingTime == "Last Week")
        #expect(v.subquestions.count == 3)
        #expect(QueryPlan(people: [.init(name: "me", role: .selfUser)]).validated(question: "Who could take on the rollout?").people.isEmpty,
                "no self person unless the question says I/me/my")
        #expect(QueryPlan(people: [.init(name: "Al", role: .speaker)]).validated(question: "What else was also decided?").people.isEmpty, "whole-word grounding")
        #expect(QueryPlan(people: [.init(name: "Al", role: .speaker)]).validated(question: "What did Al's team say? Ask Al.").people.count == 1)
    }

    @Test func vectorsAndProducerIdentity() {
        #expect(!VectorCheck.isValid([0, 0], dimensions: 2))
        #expect(!VectorCheck.isValid([.nan, 1], dimensions: 2))
        #expect(!VectorCheck.isValid([1], dimensions: 2))
        #expect(VectorCheck.isValid([0.6, 0.8], dimensions: 2))
        let p = EncoderProducer(family: "f", manifestID: "m", revision: "r", weightsSHA256: "h", quantization: "q", dimensions: 1024, pooling: "last",
                                normalization: "l2", queryInstruction: "i", documentPrefix: "", chunking: "chunk-v1", runtime: "rt")
        var p2 = p; p2.dimensions = 512
        var p3 = p; p3.queryInstruction = "j"
        #expect(p.id != p2.id && p.id != p3.id && p.id == p.id)
        #expect(EmbedResponse(producer: p2, vectors: EmbedResponse.pack([[Float](repeating: 0.5, count: 512)]), seconds: 0, loaded: false).unpacked().first?.count == 512)
    }
}
