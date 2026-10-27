import Foundation
import Testing
@testable import Capture
import Domain
import Storage

/// T68: stopping while the quiet alert is up ends the meeting at the last words + 5 s and deletes the tail for good.
@Suite("Quiet tail trim", .serialized)
struct CaptureTrimTests {
    static let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)

    func record(seconds: Double, root: URL, store: MeetingStore) async throws -> CaptureResult {
        let plan = SyntheticSource.Plan(format: Self.fmt, callbackFrames: 320, speed: 1) { i, _ in Float(i % 100_000) / 100_000 }
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly),
                                     store: store) { kind in SyntheticSource(kind: kind, plan: plan) }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .seconds(seconds))
        return s.stop()
    }

    @Test func planKeepsWholeSegmentsBeforeTheCut() throws {
        let m = MeetingID("t")
        let e = EpochID("e")
        func seg(_ i: Int) -> AudioSegmentRecord {
            AudioSegmentRecord(id: AudioSegmentID("s\(i)"), meetingID: m, source: .microphone, epochID: e, sequence: Int64(i), format: Self.fmt,
                               firstFrameInEpoch: Int64(i) * 32_000, frameCount: 32_000, interval: .seconds(Double(i) * 2, Double(i + 1) * 2),
                               relativePath: "audio/mic/\(i).caf", sha256: "", state: .committed)
        }
        let segments = (0..<10).map(seg)   // 0–20 s
        let pause = CaptureEvent(meetingID: m, source: nil, interval: .seconds(15, 16), kind: .pause, reasonCode: "user", recoverable: true)
        let early = CaptureEvent(meetingID: m, source: nil, interval: .seconds(1, 2), kind: .pause, reasonCode: "user", recoverable: true)
        let p = try #require(CaptureTrim.plan(segments: segments, events: [early, pause], duration: .seconds(20), end: .seconds(9)))
        #expect(p.keep.map(\.sequence) == [0, 1, 2, 3, 4], "the segment holding 9 s (8–10 s) is kept whole")
        #expect(p.drop.map(\.sequence) == [5, 6, 7, 8, 9])
        #expect(p.duration == .seconds(10))
        #expect(p.removedSeconds == 10)
        #expect(p.dropEvents == [pause] && p.keptEvents == [early])
        #expect(CaptureTrim.plan(segments: segments, events: [], duration: .seconds(20), end: .seconds(20)) == nil, "nothing to cut")
        #expect(CaptureTrim.plan(segments: segments, events: [], duration: .seconds(20), end: .seconds(19)) == nil, "the last segment holds the cut")
    }

    @Test func applyRemovesRowsFilesAndJournalLinesAndRecoveryDoesNotRestoreThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-trim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        // Real-time synthetic audio, so segment times and the session's duration agree (as in a real recording).
        let r = try await record(seconds: 6.5, root: root, store: store)
        try #require(r.segments.count >= 3)
        let cut = r.segments[1].interval.end   // keep two segments
        let plan = try #require(CaptureTrim.plan(r, end: cut))
        let out = try CaptureTrim.apply(plan, to: r, store: store)

        #expect(out.segments.map(\.id) == Array(r.segments.prefix(2)).map(\.id))
        #expect(try store.segments(r.meetingID).map(\.id) == out.segments.map(\.id))
        #expect(try store.meeting(r.meetingID)?.duration == plan.duration)
        #expect(plan.duration.seconds < r.duration.seconds)
        for s in plan.drop { #expect(!FileManager.default.fileExists(atPath: r.directory.appending(path: s.relativePath).path)) }
        for s in plan.keep { #expect(FileManager.default.fileExists(atPath: r.directory.appending(path: s.relativePath).path)) }
        let journal = try String(contentsOf: r.directory.appending(path: "journal.jsonl"), encoding: .utf8)
        for s in plan.drop { #expect(!journal.contains(s.relativePath)) }

        // Next launch's crash recovery: nothing comes back, nothing is reported damaged.
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: store)
        // (Under /var → /private/var, recovery re-reports kept files as reindexed; those inserts are no-ops.)
        #expect(Set(res.report.reindexed).isDisjoint(with: plan.drop.map(\.id)) && res.report.quarantined.isEmpty)
        #expect(try store.segments(r.meetingID).count == 2)
        // Even after losing the database, the tail stays gone (files and journal agree).
        for name in ["amaranth.sqlite", "amaranth.sqlite-wal", "amaranth.sqlite-shm"] { try? FileManager.default.removeItem(at: root.appending(path: name)) }
        let fresh = try MeetingStore(root: root)
        _ = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: fresh)
        #expect(try fresh.segments(r.meetingID).map(\.id) == out.segments.map(\.id))
    }
}
