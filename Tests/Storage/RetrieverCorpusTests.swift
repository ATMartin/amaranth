import Foundation
import Testing
@testable import Storage
import Domain

/// T53 acceptance: retrieval latency over the corpus meetings (baseline-v0 transcripts and notes, the longest being the
/// 71-minute working session) and over a copy of the work-Mac library's database (migrated v2 → v4 on open). Needs the
/// local, git-ignored Tests/Data/Recordings; skipped without it. Prints one JSON line per scope with the timings.
enum CorpusData {
    static let recordings = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Data/Recordings")
    static var available: Bool { FileManager.default.fileExists(atPath: recordings.appending(path: "baseline-v0/outputs").path) }
}

@Suite("Retriever on the corpus (T53)", .enabled(if: CorpusData.available))
struct RetrieverCorpusTests {
    static var recordings: URL { CorpusData.recordings }

    static let questions = [
        "What did they decide about the release?", "Who is going to follow up on the budget?", "What was said about testing?",
        "When is the next meeting?", "What did Speaker 2 say about the customer?", "Were there any concerns about hiring?",
        "What are the action items?", "What tools did they mention?", "What happened with the deadline?", "Did anyone talk about AI agents?",
    ]

    /// Builds a library from the baseline-v0 corpus outputs (transcript + notes per corpus meeting).
    static func corpusStore(at root: URL) throws -> (MeetingStore, [MeetingID: Int]) {
        let store = try MeetingStore(root: root)
        var segments: [MeetingID: Int] = [:]
        let outputs = recordings.appending(path: "baseline-v0/outputs")
        for name in try FileManager.default.contentsOfDirectory(atPath: outputs.path).sorted() where name.hasPrefix("corpus-") {
            let dir = outputs.appending(path: "\(name)/default")
            guard let tdata = try? Data(contentsOf: dir.appending(path: "transcript.json")) else { continue }
            let t = try ContractCoding.decode(TranscriptRevision.self, from: tdata)
            let end = t.segments.map(\.interval.end).max() ?? .zero
            try store.upsertMeeting(Meeting(id: t.meetingID, title: String(name.dropFirst("corpus-".count)), createdAt: t.createdAt,
                                            captureState: .captured, duration: end - .zero))
            _ = try store.publishTranscript(t)
            if let sdata = try? Data(contentsOf: dir.appending(path: "summary.json")) {
                _ = try store.publishSummary(try ContractCoding.decode(SummaryRevision.self, from: sdata))
            }
            segments[t.meetingID] = t.segments.count
        }
        return (store, segments)
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let t0 = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func report(_ label: String, _ ms: [Double], passages: Int) -> (median: Double, max: Double) {
        let s = ms.sorted()
        let median = s[s.count / 2], mx = s.last ?? 0
        print(#"{"retrieval":"\#(label)","questions":\#(ms.count),"medianMs":\#(String(format: "%.1f", median)),"maxMs":\#(String(format: "%.1f", mx)),"passages":\#(passages)}"#)
        return (median, mx)
    }

    @Test func longestCorpusMeetingUnder50ms() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-retr-corpus-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, segments) = try Self.corpusStore(at: root)
        let longest = try #require(segments.max { $0.value < $1.value }?.key)
        let retriever = Retriever(store: store)
        for q in Self.questions { _ = try retriever.search(q) }   // warm the page cache
        for (label, scope) in [("longest-meeting(\(segments[longest]!) segments)", Optional(longest)), ("all-corpus(\(segments.count) meetings)", nil)] {
            var ms: [Double] = [], n = 0
            for _ in 0..<3 {
                for q in Self.questions { ms.append(try Self.time { n += try retriever.search(q, in: scope).count }) }
            }
            let r = Self.report(label, ms, passages: n)
            #expect(r.median < 50 && r.max < 50, "\(label): every question under 50 ms")
            #expect(n > 0)
        }
    }

    /// The work-Mac library (real recordings, schema v2): the copy is migrated and re-indexed on open.
    @Test func workMacLibraryCopy() throws {
        let src = Self.recordings.appending(path: "libraries/work-mac")
        guard FileManager.default.fileExists(atPath: src.appending(path: "amaranth.sqlite").path) else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-retr-work-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for f in ["amaranth.sqlite", "amaranth.sqlite-wal", "amaranth.sqlite-shm"] where FileManager.default.fileExists(atPath: src.appending(path: f).path) {
            try FileManager.default.copyItem(at: src.appending(path: f), to: root.appending(path: f))
        }
        var store: MeetingStore?
        let openMs = try Self.time { store = try MeetingStore(root: root) }
        print(#"{"migration":"work-mac v2→v4","openAndReindexMs":\#(String(format: "%.0f", openMs))}"#)
        let retriever = Retriever(store: try #require(store))
        var ms: [Double] = [], n = 0
        for q in Self.questions { ms.append(try Self.time { n += try retriever.search(q).count }) }
        let r = Self.report("work-mac", ms, passages: n)
        #expect(r.max < 50)
    }
}
