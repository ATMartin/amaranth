import Foundation
import Capture
import Domain
import Presentation
import Storage

/// `Amaranth --self-test live-latency --repo <repo>`: records a two-source synthetic replay in real time (mic:
/// LibriSpeech, system: AMI EN2002a) while live text runs through the real XPC worker, and reports provisional-text
/// latency (median/p95), provisional mic WER, capture loss and memory. No audio permission is needed.
///
/// `live-load` (T19, gate G6): the same recording under a simulated call load. Incremental processing runs on it, and
/// the stages of an earlier 20-minute meeting run beside it (back to back). Capture must lose nothing, live text must
/// still meet its gate, and the app's footprint is reported for comparison with `live-latency`.
@MainActor
enum LiveSelfTest {
    /// `pressure`: simulate thermal pressure for 15 s mid-recording; live text must pause, capture must lose nothing,
    /// and live text must catch up to the end afterwards.
    static func run(pressure: Bool = false, load: Bool = false) async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(root: root)
            let f = try PipelineSelfTest.fixture(systemSeconds: 120)
            let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
            // Load: an earlier meeting, captured first (fast replay), whose stages run during this recording.
            var earlier: MeetingID?
            if load {
                let bg = try PipelineSelfTest.fixture(systemSeconds: 1200).system
                let bgSession = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: .systemOnly),
                                                     store: store, title: "Earlier meeting") { kind in
                    SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: fmt, callbackFrames: 1024, speed: 20) { i, _ in i < bg.count ? bg[Int(i)] : 0 })
                }
                try bgSession.start()
                _ = await bgSession.waitUntilRecording()
                try await Task.sleep(for: .seconds(Double(bg.count) / 16_000 / 20 + 1))
                earlier = bgSession.stop().meetingID
            }
            let mic = f.mic, sys = f.system
            let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: .both),
                                               store: store, title: "Live self-test") { kind in
                let samples = kind == .microphone ? mic : sys
                return SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: fmt, callbackFrames: 512, speed: 1) { i, _ in
                    i < samples.count ? samples[Int(i)] : 0
                })
            }
            let client = WorkerClient()
            guard case .pong(let workerPID, _)? = try? await client.send(.ping) else { log(["step": "worker", "ok": "false"]); return false }
            // T20 experiments: `--live-tick <s>` and `--live-per-source yes|no` override the app's live text settings.
            let args = CommandLine.arguments
            func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let defaults = LiveTextModel(client: client)
            let live = LiveTextModel(client: client, interval: arg("--live-tick").flatMap(Double.init) ?? defaults.interval,
                                     perSource: arg("--live-per-source").map { $0 == "yes" } ?? defaults.perSource)
            live.modelsReady = ModelSetupModel.isReady
            let pressureOn = LockedFlag()
            if pressure { live.pauseReason = { pressureOn.value ? "simulated thermal pressure" : nil } }
            var sawPaused = false
            let recordingFlag = LockedFlag(), faultFlag = LockedFlag()
            recordingFlag.value = true
            let scheduler = load ? PipelineSelfTest.scheduler(store: store, client: client, processWhileRecording: true) {
                faultFlag.value ? .captureFault : recordingFlag.value ? .recording : .none
            } : nil
            let incremental = load ? IncrementalProcessor(client: client) : nil
            incremental?.onFinal = { [weak live] s in live?.applyFinal(s) }
            try session.start()
            _ = await session.waitUntilRecording()
            live.start(session: session, store: store)
            if let scheduler, let earlier {
                try scheduler.start()
                try scheduler.enqueuePipeline(earlier)
            }
            incremental?.start(.init(meetingID: session.meetingID, meetingDirectory: session.directory,
                                     workDirectory: store.workDirectory(session.meetingID).appending(path: "incremental")) { [weak session] in
                session.map { s in let r = s.snapshot(); return (r.segments, r.events) }
            })
            var faults = 0, lastOverruns = 0
            let seconds = Double(max(mic.count, sys.count)) / 16_000 + 4
            var maxApp: UInt64 = 0, maxWorker: UInt64 = 0
            let t0 = ContinuousClock.now
            while ContinuousClock.now - t0 < .seconds(seconds) {
                try await Task.sleep(for: .seconds(1))
                maxApp = max(maxApp, ProcessMetrics.physicalFootprint())
                maxWorker = max(maxWorker, footprint(pid: workerPID))
                let elapsed = (ContinuousClock.now - t0).components.seconds
                if pressure { pressureOn.value = elapsed >= 40 && elapsed < 55 }
                if case .paused = live.status { sawPaused = true }
                // The app's capture-fault back-off (ProcessingModel.observeCapture), counted: it must never trigger.
                let h = session.health()
                let overruns = h.map(\.overrunCount).reduce(0, +)
                if h.contains(where: { [.degraded, .failed].contains($0.status) }) || overruns > lastOverruns { faults += 1; faultFlag.value = true }
                lastOverruns = overruns
            }
            let r = session.stop()
            incremental?.stop()
            recordingFlag.value = false
            // Flush the remaining audio and publish the provisional revision, as the app does at Stop.
            await live.finish(r)
            let st = live.state
            let micText = st.words.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
            let wer = SimpleWER.wer(reference: f.micReference, hypothesis: micText)
            let median = st.percentile(0.5) ?? .infinity, p95 = st.percentile(0.95) ?? .infinity
            let overruns = r.ringStats.values.map(\.overrunEvents).reduce(0, +)
            let published = try store.meeting(r.meetingID)?.provisionalTranscriptRevisionID != nil
            if ProcessInfo.processInfo.environment["AMARANTH_LIVE_DEBUG"] != nil {
                for w in st.words where w.source == .microphone { FileHandle.standardError.write(Data("\(String(format: "%.2f", w.interval.start.seconds)) \(w.text)\n".utf8)) }
            }
            log(["step": "live", "status": "\(live.status)", "tick": "\(live.interval)", "perSource": "\(live.perSource)", "words": "\(st.words.count)", "latencyMedianSeconds": String(format: "%.2f", median),
                 "latencyP95Seconds": String(format: "%.2f", p95), "samples": "\(st.latencies.count)",
                 "micProvisionalWER": String(format: "%.1f%%", wer * 100), "provisionalPublished": "\(published)"])
            log(["step": "capture", "segments": "\(r.segments.count)", "missingAudioEvents": "\(r.events.filter(\.isMissingAudio).count)",
                 "ringOverruns": "\(overruns)", "appPeakMiB": String(format: "%.0f", Double(maxApp) / 1_048_576),
                 "workerPeakMiB": String(format: "%.0f", Double(maxWorker) / 1_048_576)])
            let captureOK = r.events.filter(\.isMissingAudio).isEmpty && overruns == 0 && published
            if load {
                let jobs = try earlier.map { try store.jobs(meeting: $0) } ?? []
                let ranDuring = jobs.filter { [.transcribe, .diarize].contains($0.key.stage) && $0.state == .succeeded }.count
                let st = incremental?.stats
                let finalized = st?.finalizedUntil.values.min() ?? 0
                let audioEnd = r.segments.map(\.interval.end.seconds).max() ?? 0
                let finalWords = st.map { _ in live.state.sources.values.map(\.final.count).reduce(0, +) } ?? 0
                log(["step": "load", "earlierMeetingStagesDone": "\(ranDuring)", "earlierJobs": jobs.map { "\($0.key.stage.rawValue)=\($0.state.rawValue)" }.joined(separator: ","),
                     "incrementalRequests": "\(st?.requests ?? 0)", "incrementalFailures": "\(st?.failures ?? 0)",
                     "finalizedUntil": String(format: "%.0f", finalized), "audioEnd": String(format: "%.0f", audioEnd), "finalWordsShown": "\(finalWords)",
                     "captureFaultBackoffs": "\(faults)"])
                scheduler?.stop()
                return captureOK && faults == 0 && median < 5 && p95 < 10 && wer < 0.15 && ranDuring == 2 && finalized > audioEnd - 90 && finalWords > 0
            }
            if pressure {
                let ends = st.sources.mapValues(\.processedUntil.seconds)
                let audioEnd = r.segments.map(\.interval.end.seconds).max() ?? 0
                let caughtUp = ends.values.allSatisfy { $0 >= audioEnd - 4 }
                log(["step": "pressure", "sawPaused": "\(sawPaused)", "caughtUp": "\(caughtUp)",
                     "processedUntil": ends.map { "\($0.key.rawValue)=\(Int($0.value))" }.joined(separator: ","), "audioEnd": "\(Int(audioEnd))"])
                return sawPaused && caughtUp && captureOK && wer < 0.15
            }
            return median < 5 && p95 < 10 && wer < 0.15 && captureOK
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }

    /// Physical footprint of another process (the worker), via proc_pid_rusage.
    static func footprint(pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
