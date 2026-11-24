import Foundation
import Capture
import Domain
import Presentation
import Storage

/// T20 `Amaranth --self-test live-replay --live-spec <spec.json> [--self-test-output f.jsonl]`, driven by
/// `amaranth-bench live-suite`. Each item is an excerpt of a recorded meeting (from a private library copy), replayed
/// in real time through the real capture path into a temporary store while live text runs through the real XPC worker,
/// with incremental processing beside it as in the app. Writes `LiveReplay.Result` and `live-latency.json` per item.
/// Metrics only: live words are compared with the meeting's final transcript in memory and never written.
@MainActor
enum LiveReplaySelfTest {
    static func run(specURL: URL) async -> Bool {
        let log = SelfTest.log
        do {
            let spec = try ContractCoding.decode(LiveReplay.Spec.self, from: Data(contentsOf: specURL))
            let client = WorkerClient()
            guard case .pong(let workerPID, _)? = try? await client.send(.ping) else { log(["step": "worker", "ok": "false"]); return false }
            var ok = true
            for item in spec.items {
                let out = URL(filePath: spec.outputDirectory).appending(path: item.id)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                var result: LiveReplay.Result
                do {
                    result = try await replay(item, spec: spec, client: client, workerPID: workerPID, output: out)
                } catch {
                    result = LiveReplay.Result(id: item.id, completed: false, failure: "\(error)", audioSeconds: item.seconds, tickSeconds: spec.tickSeconds,
                                               perSource: spec.perSource, incremental: spec.incremental)
                }
                try ContractCoding.encode(result).write(to: out.appending(path: "result.json"), options: .atomic)
                log(["step": "item", "id": item.id, "completed": "\(result.completed)", "failure": result.failure ?? "",
                     "median": result.medianSeconds.map { String(format: "%.2f", $0) } ?? "-", "p95": result.p95Seconds.map { String(format: "%.2f", $0) } ?? "-",
                     "samples": "\(result.latencies.count)", "waitingMedian": result.medianWaiting.map { String(format: "%.2f", $0) } ?? "-",
                     "workerMedian": result.medianWorker.map { String(format: "%.2f", $0) } ?? "-",
                     "disagreement": result.sources.map { "\($0.source)=\($0.disagreementWithFinal.map { String(format: "%.3f", $0) } ?? "-")" }.joined(separator: ",")])
                ok = ok && result.completed
            }
            return ok
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }

    static func replay(_ item: LiveReplay.Item, spec: LiveReplay.Spec, client: WorkerClient, workerPID: Int32, output: URL) async throws -> LiveReplay.Result {
        let library = try MeetingStore(root: URL(filePath: item.library))
        let meetingID = MeetingID(item.meetingID)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "amaranth-live-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The excerpt of each source as raw interleaved float32 at its recorded format (memory-mapped while replaying).
        var inputs: [SourceKind: PerfSelfTest.MappedAudio] = [:]
        for kind in SourceKind.allCases {
            if let raw = try excerpt(library: library, meeting: meetingID, source: kind, start: item.start, seconds: item.seconds,
                                     to: scratch.appending(path: "\(kind.rawValue).f32")) {
                inputs[kind] = try PerfSelfTest.MappedAudio(raw)
            }
        }
        guard !inputs.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let store = try MeetingStore(root: scratch.appending(path: "store"))
        let selection: SourceSelection = inputs.count == 2 ? .both : inputs[.microphone] != nil ? .microphoneOnly : .systemOnly
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: selection),
                                           store: store, title: item.id) { kind in
            let audio = inputs[kind]!
            return SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: audio.format, callbackFrames: 480, speed: 1) { i, c in audio.sample(i, c) })
        }
        let live = LiveTextModel(client: client, interval: spec.tickSeconds, perSource: spec.perSource)
        live.modelsReady = ModelSetupModel.isReady
        let incremental = spec.incremental ? IncrementalProcessor(client: client) : nil
        incremental?.onFinal = { [weak live] s in live?.applyFinal(s) }
        try session.start()
        _ = await session.waitUntilRecording()
        live.start(session: session, store: store)
        incremental?.start(.init(meetingID: session.meetingID, meetingDirectory: session.directory,
                                 workDirectory: store.workDirectory(session.meetingID).appending(path: "incremental")) { [weak session] in
            session.map { s in let r = s.snapshot(); return (r.segments, r.events) }
        })
        var maxApp: UInt64 = 0, maxWorker: UInt64 = 0
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < .seconds(item.seconds + 0.5) {
            try await Task.sleep(for: .seconds(1))
            maxApp = max(maxApp, ProcessMetrics.physicalFootprint())
            maxWorker = max(maxWorker, LiveSelfTest.footprint(pid: workerPID))
        }
        let r = session.stop()
        incremental?.stop()
        await live.finish(r)
        if let data = try? Data(contentsOf: r.directory.appending(path: LiveLatencyLog.fileName)) {
            try data.write(to: output.appending(path: LiveLatencyLog.fileName), options: .atomic)
        }
        // Agreement with the meeting's final transcript over the excerpt, per source (words placed by midpoint).
        let st = live.state
        let final = try library.meeting(meetingID)?.currentTranscriptRevisionID.flatMap { try library.transcriptRevision($0) }
        var sources: [LiveReplay.Result.Source] = []
        for kind in inputs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let ref = final?.allWords.filter { w in
                let mid = (w.interval.start.seconds + w.interval.end.seconds) / 2 - item.start
                return w.source == kind && mid >= 0 && mid < item.seconds
            }.map(\.text) ?? []
            let hyp = st.words.filter { $0.source == kind }.map(\.text)
            let lat = st.samples.filter { $0.source == kind }.map(\.seconds)
            sources.append(.init(source: kind.rawValue, samples: lat.count, medianSeconds: LiveLatencyLog.percentile(lat, 0.5),
                                 p95Seconds: LiveLatencyLog.percentile(lat, 0.95),
                                 disagreementWithFinal: ref.isEmpty ? nil : SimpleWER.wer(reference: ref.joined(separator: " "), hypothesis: hyp.joined(separator: " ")),
                                 finalWords: ref.count, liveWords: hyp.count))
        }
        let missing = r.events.filter(\.isMissingAudio).count
        let overruns = Int(r.ringStats.values.map(\.overrunEvents).reduce(0, +))
        var result = LiveReplay.Result(id: item.id, completed: missing == 0 && overruns == 0 && !st.samples.isEmpty,
                                       audioSeconds: item.seconds, tickSeconds: spec.tickSeconds, perSource: spec.perSource, incremental: spec.incremental,
                                       requests: (try? ContractCoding.decode(LiveLatencyLog.self, from: Data(contentsOf: output.appending(path: LiveLatencyLog.fileName))))?.requests ?? 0,
                                       latencies: st.latencies.map { ($0 * 1000).rounded() / 1000 }, sources: sources,
                                       missingAudioEvents: missing, ringOverruns: overruns,
                                       appPeakMiB: Double(maxApp) / 1_048_576, workerPeakMiB: Double(maxWorker) / 1_048_576)
        if !result.completed { result.failure = st.samples.isEmpty ? "no live words" : "capture loss during replay" }
        result.medianSeconds = LiveLatencyLog.percentile(st.latencies, 0.5)
        result.p95Seconds = LiveLatencyLog.percentile(st.latencies, 0.95)
        result.medianUnsaved = LiveLatencyLog.percentile(st.samples.compactMap(\.unsaved), 0.5)
        result.medianWaiting = LiveLatencyLog.percentile(st.samples.compactMap(\.waiting), 0.5)
        result.medianWorker = LiveLatencyLog.percentile(st.samples.compactMap(\.worker), 0.5)
        result.p95Waiting = LiveLatencyLog.percentile(st.samples.compactMap(\.waiting), 0.95)
        result.p95Worker = LiveLatencyLog.percentile(st.samples.compactMap(\.worker), 0.95)
        return result
    }

    /// Writes one source's audio over [start, start + seconds) of session time, at the first overlapping segment's
    /// format; gaps stay silent. Returns nil if the source has no audio there.
    static func excerpt(library: MeetingStore, meeting: MeetingID, source: SourceKind, start: Double, seconds: Double, to url: URL) throws -> PerfRun.RawAudio? {
        let segs = try library.segments(meeting, source: source).filter {
            $0.state == .committed && $0.interval.end.seconds > start && $0.interval.start.seconds < start + seconds
        }
        // Written segment by segment into a zero-filled file, so the app never holds the excerpt in memory (its peak
        // footprint is reported).
        var format: AudioFormat?
        var handle: FileHandle?
        defer { try? handle?.close() }
        var total = 0
        for seg in segs {
            try autoreleasepool {
                let d = try CAFFile.decode(Data(contentsOf: library.meetingDirectory(meeting).appending(path: seg.relativePath)), salvage: true)
                if format == nil {
                    format = d.format
                    total = Int(seconds * Double(d.format.sampleRate))
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.truncate(atOffset: UInt64(total * d.format.channelCount * 4))
                }
                guard let f = format, d.format == f, let handle else { return }
                let ch = f.channelCount
                let at = Int(((seg.interval.start.seconds - start) * Double(f.sampleRate)).rounded())
                let lo = max(0, -at), hi = min(d.frameCount, total - at)
                guard hi > lo else { return }
                try handle.seek(toOffset: UInt64((at + lo) * ch * 4))
                d.samples[(lo * ch)..<(hi * ch)].withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
            }
        }
        guard let f = format else { return nil }
        return PerfRun.RawAudio(path: url.path, sampleRate: f.sampleRate, channels: f.channelCount)
    }
}
