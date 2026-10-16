import Foundation
import Capture
import Domain
import Presentation
import Storage

/// `Amaranth --self-test live-latency --repo <repo>`: records a two-source synthetic replay in real time (mic:
/// LibriSpeech, system: AMI EN2002a) while live text runs through the real XPC worker, and reports provisional-text
/// latency (median/p95), provisional mic WER, capture loss and memory. No audio permission is needed.
@MainActor
enum LiveSelfTest {
    /// `pressure`: simulate thermal pressure for 15 s mid-recording; live text must pause, capture must lose nothing,
    /// and live text must catch up to the end afterwards.
    static func run(pressure: Bool = false) async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-live-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(root: root)
            let f = try PipelineSelfTest.fixture(systemSeconds: 120)
            let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
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
            let live = LiveTextModel(client: client)
            live.modelsReady = ModelSetupModel.isReady
            let pressureOn = LockedFlag()
            if pressure { live.pauseReason = { pressureOn.value ? "simulated thermal pressure" : nil } }
            var sawPaused = false
            try session.start()
            _ = await session.waitUntilRecording()
            live.start(session: session, store: store)
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
            }
            let r = session.stop()
            // Let the in-flight pass land, then stop live text (publishes the provisional revision).
            try await Task.sleep(for: .seconds(3))
            live.stop(publish: true)
            let st = live.state
            let micText = st.words.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
            let wer = SimpleWER.wer(reference: f.micReference, hypothesis: micText)
            let median = st.percentile(0.5) ?? .infinity, p95 = st.percentile(0.95) ?? .infinity
            let overruns = r.ringStats.values.map(\.overrunEvents).reduce(0, +)
            let published = try store.meeting(r.meetingID)?.provisionalTranscriptRevisionID != nil
            if ProcessInfo.processInfo.environment["AMARANTH_LIVE_DEBUG"] != nil {
                for w in st.words where w.source == .microphone { FileHandle.standardError.write(Data("\(String(format: "%.2f", w.interval.start.seconds)) \(w.text)\n".utf8)) }
            }
            log(["step": "live", "status": "\(live.status)", "words": "\(st.words.count)", "latencyMedianSeconds": String(format: "%.2f", median),
                 "latencyP95Seconds": String(format: "%.2f", p95), "samples": "\(st.latencies.count)",
                 "micProvisionalWER": String(format: "%.1f%%", wer * 100), "provisionalPublished": "\(published)"])
            log(["step": "capture", "segments": "\(r.segments.count)", "missingAudioEvents": "\(r.events.filter(\.isMissingAudio).count)",
                 "ringOverruns": "\(overruns)", "appPeakMiB": String(format: "%.0f", Double(maxApp) / 1_048_576),
                 "workerPeakMiB": String(format: "%.0f", Double(maxWorker) / 1_048_576)])
            let captureOK = r.events.filter(\.isMissingAudio).isEmpty && overruns == 0 && published
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
