import Foundation
import Testing
@testable import Presentation
import Domain

@Suite("Live transcript state")
struct LiveTranscriptStateTests {
    func w(_ text: String, _ a: Double, _ src: SourceKind = .microphone) -> Word {
        Word(id: WordID("live-\(src.rawValue)-\(Int(a * 1000))"), text: text, interval: .seconds(a, a + 0.3), source: src)
    }

    @Test func mergesStableAndTentativeIgnoresStaleAndMeasuresLatencyOnce() throws {
        var s = LiveTranscriptState()
        s.apply(LiveResponse(source: .microphone, stableWords: [w("hello", 1)], tentativeWords: [w("wor", 2)], stableUntil: .seconds(1.5), processedUntil: .seconds(3)),
                sessionNow: .seconds(4))
        // Next pass: the tentative word is re-decoded with a slightly different start (new ID) and becomes stable.
        s.apply(LiveResponse(source: .microphone, stableWords: [w("world", 2.05)], tentativeWords: [w("again", 3)], stableUntil: .seconds(2.6), processedUntil: .seconds(4)),
                sessionNow: .seconds(6))
        #expect(s.words.map(\.text) == ["hello", "world", "again"], "tentative words are replaced, stable words kept")
        // A late, older response is ignored.
        s.apply(LiveResponse(source: .microphone, stableWords: [w("stale", 1.2)], tentativeWords: [], stableUntil: .seconds(1.5), processedUntil: .seconds(3)),
                sessionNow: .seconds(7))
        #expect(!s.words.contains { $0.text == "stale" })
        #expect(s.latencies.count == 4, "hello, wor, world (different text), again — each measured once")
        #expect(abs(s.latencies[0] - 2.7) < 0.01)   // 4.0 − (1.0 + 0.3)
        // A provisional revision is valid and marked provisional.
        let rev = try #require(s.revision(meetingID: MeetingID("m"), producer: ProducerInfo(component: "live", configHash: "l")))
        #expect(rev.kind == .provisional)
        try rev.validate()
        #expect(s.lines.last?.tentative == true)
    }
}
