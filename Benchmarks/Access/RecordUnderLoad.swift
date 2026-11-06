import Foundation
import Capture
import Domain
import Storage
import MeetingAccess

/// T100: recording health while external reads and a bulk export run on the same store (the app shares one store
/// between the recorder and everything else). Two synthetic sources (48 kHz mono mic, 48 kHz stereo system) run in
/// real time through the real ring, segment writer, journal and store indexer; their samples encode the frame index,
/// so any dropped or duplicated frame is found exactly. Real Core Audio device callbacks are not exercised.
enum RecordUnderLoad {
    /// `ctxLoad` (T116): instead of external reads, the contextual-search store work that can overlap a recording —
    /// exact vector scans over the whole library, guarded vector publication and content edits that rechunk a meeting.
    static func run(root: URL, seconds: Double, exportDest: URL, load: Bool, ctxLoad: Bool = false) async throws {
        let store = try MeetingStore(root: root)
        let reader = MeetingReader(store: store)
        let ids = try store.liveMeetingIDs()
        let mono = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
        let stereo = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)
        func plan(_ f: AudioFormat) -> SyntheticSource.Plan { SyntheticSource.Plan(format: f, callbackFrames: 512, speed: 1) { i, c in Float(i % 1_000_000) + Float(c) * 0.5 } }
        let meeting = MeetingID()
        let session = try RecordingSession(meetingID: meeting, rootDirectory: root, options: RecordingOptions(selection: .both), store: store,
                                           title: "record-under-load") { kind in SyntheticSource(kind: kind, plan: kind == .microphone ? plan(mono) : plan(stereo)) }
        try session.start()
        guard await session.waitUntilRecording() else { print("{\"error\":\"not recording\"}"); return }
        let recordingStarted = Date()
        let stop = Flag()
        let ops = Counter(), exports = Counter()
        var workers: [Thread] = []
        if ctxLoad {
            let probe = EncoderProducer(family: "ctxload", manifestID: "ctxload", revision: "1", weightsSHA256: "-", quantization: "-", dimensions: 1024,
                                        pooling: "-", normalization: "l2", queryInstruction: "", documentPrefix: "", chunking: ChunkingVersion.current, runtime: "ctxload")
            func unit(_ r: inout Synthetic.RNG) -> [Float] {
                var v = (0..<1024).map { _ in Float(Int.random(in: -1000...1000, using: &r)) / 1000 }
                let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); v = v.map { $0 / max(n, 1e-6) }; return v
            }
            for w in 0..<2 {   // two scan threads (Ask-like) over every meeting
                let t = Thread {
                    var r = Synthetic.RNG(state: UInt64(w + 11))
                    while !stop.isSet { _ = try? store.vectorSearch(unit(&r), producer: probe, filter: ContextFilter(), k: 100); ops.add(1) }
                }
                t.start(); workers.append(t)
            }
            let writer = Thread {   // indexing-like writes + rechunking edits
                var r = Synthetic.RNG(state: 99)
                var seq = 1000
                while !stop.isSet {
                    if let batch = try? store.pendingContextChunks(producer: probe.id, limit: 32), !batch.isEmpty {
                        _ = try? store.publishContextVectors(batch.map { ($0.contentHash, unit(&r)) }, producer: probe)
                    }
                    if let m = ids.randomElement(using: &r), let tr = try? store.meeting(m)?.currentTranscriptRevisionID,
                       let seg = try? store.transcriptRevision(tr)?.segments.randomElement(using: &r), let w = seg.words.first {
                        seq += 1
                        _ = try? store.appendEdit(UserEdit(meetingID: m, baseRevisionID: tr, sequence: seq, createdAt: Date(),
                                                           operation: .correctText(WordRange(revisionID: tr, first: w.id, last: w.id), replacement: w.text)))
                    }
                    exports.add(1)
                }
            }
            writer.start(); workers.append(writer)
        } else if load {
            for w in 0..<2 {
                let t = Thread {
                    var r = Synthetic.RNG(state: UInt64(w + 1))
                    while !stop.isSet {
                        _ = try? reader.searchMeetings(SearchMeetingsRequest(query: Scale.queries.randomElement(using: &r)!, limit: 20))
                        _ = try? reader.getMeeting(GetMeetingRequest(meetingID: ids.randomElement(using: &r)!.rawValue, section: .transcript))
                        _ = try? reader.listMeetings(ListMeetingsRequest(limit: 50))
                        ops.add(3)
                    }
                }
                t.start(); workers.append(t)
            }
            let e = Thread {
                var n = 0
                while !stop.isSet {
                    n += 1
                    _ = BulkExport.run(reader, meetings: ids, content: .notesAndTranscript, destination: exportDest.appending(path: "run\(n)"), isCancelled: { stop.isSet })
                    exports.add(1)
                }
            }
            e.start(); workers.append(e)
        }
        try await Task.sleep(for: .seconds(seconds))
        let elapsed = Date().timeIntervalSince(recordingStarted)   // up to the stop request; stopping itself records nothing new
        let stopStarted = Date()
        let result = session.stop()
        let stopSeconds = Date().timeIntervalSince(stopStarted)
        stop.set()
        while workers.contains(where: { !$0.isFinished }) { try await Task.sleep(for: .milliseconds(50)) }

        // Frame-exact check: every frame's first channel must be the previous frame's + 1 (mod 1,000,000), inside segments
        // and across them, and the total must match the time recorded (within 0.25 s: start-up and stop).
        var report: [String: Any] = ["load": load, "ctxLoad": ctxLoad, "seconds": seconds, "elapsedSeconds": elapsed, "stopSeconds": stopSeconds, "finalState": result.finalState.rawValue,
                                     "readerOps": ops.value, "exportRuns": exports.value, "missingAudioEvents": result.events.filter(\.isMissingAudio).count]
        for kind in SourceKind.allCases {
            var expected: Float = 0, dropped = 0, frames = 0
            let segs = result.segments.filter { $0.source == kind }.sorted { $0.sequence < $1.sequence }
            for s in segs {
                let d = try CAFFile.decode(Data(contentsOf: result.directory.appending(path: s.relativePath)))
                for f in 0..<d.frameCount {
                    let v = d.samples[f * d.format.channelCount]
                    if v != expected { dropped += 1 }
                    expected = v + 1
                    if expected >= 1_000_000 { expected -= 1_000_000 }
                }
                frames += d.frameCount
            }
            let expectedFrames = elapsed * 48_000
            let ring = result.ringStats[kind], writer = result.writerStats[kind]
            report[kind.rawValue] = ["segments": segs.count, "frames": frames, "discontinuities": dropped,
                                     "framesVsElapsed": Double(frames) - expectedFrames, "framesMatchElapsed": abs(Double(frames) - expectedFrames) <= 0.25 * 48_000,
                                     "ringOverrunFrames": ring?.overrunFrames ?? 0, "maxCallbackMicros": (ring?.maxCallbackNanos ?? 0) / 1000,
                                     "writerLostFrames": writer?.lostFrames ?? 0, "writerGapEvents": writer?.gapEvents ?? 0]
        }
        report["indexedSegments"] = try store.segments(meeting).count
        report["sessionSegments"] = result.segments.count
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    final class Flag: @unchecked Sendable { private let l = NSLock(); private var v = false; var isSet: Bool { l.withLock { v } }; func set() { l.withLock { v = true } } }
    final class Counter: @unchecked Sendable { private let l = NSLock(); private var v = 0; var value: Int { l.withLock { v } }; func add(_ n: Int) { l.withLock { v += n } } }
}
