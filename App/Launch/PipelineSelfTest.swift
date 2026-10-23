import Foundation
import Capture
import Domain
import ProcessingCore
import Storage

/// Milestone B self-tests through the real XPC worker with the installed model pack. Sources are synthetic replays of
/// public audio, so no audio permission is needed:
///   Amaranth --self-test pipeline-e2e --repo <repo>
///   Amaranth --self-test kill-worker-while-recording --repo <repo>
@MainActor
enum PipelineSelfTest {
    static func repo() -> URL {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--repo").map { URL(filePath: args[$0 + 1]) } ?? URL(filePath: FileManager.default.currentDirectoryPath)
    }

    /// 16 kHz mono PCM16 WAV → floats (skipping the RIFF header; handles extra chunks).
    static func loadWAV(_ url: URL, maxSeconds: Double = .infinity) throws -> [Float] {
        let wav = try Data(contentsOf: url)
        var off = 12, start = 44, len = wav.count - 44
        while off + 8 <= wav.count {
            let id = String(decoding: wav[off..<off + 4], as: UTF8.self)
            let n = Int(wav.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)) })
            if id == "data" { start = off + 8; len = min(n, wav.count - start); break }
            off += 8 + n + (n & 1)
        }
        let count = maxSeconds.isFinite ? min(len / 2, Int(maxSeconds * 16_000)) : len / 2
        return wav.withUnsafeBytes { raw in (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: start + $0 * 2, as: Int16.self))) / 32768 } }
    }

    struct Fixture { var mic: [Float]; var micReference: String; var system: [Float] }

    static func fixture(systemSeconds: Double) throws -> Fixture {
        let r = repo()
        let inputs = r.appending(path: "Benchmarks/Results/2026-10-16-t02-run1/inputs")
        let trans = try String(contentsOf: r.appending(path: "Benchmarks/Fixtures/public/librispeech-test-clean/1089/134686/1089-134686.trans.txt"), encoding: .utf8)
        var mic: [Float] = [], refs: [String] = []
        for line in trans.split(separator: "\n").prefix(10) {
            let parts = line.split(separator: " ", maxSplits: 1)
            mic += try loadWAV(inputs.appending(path: "\(parts[0]).wav")) + [Float](repeating: 0, count: 12_000)
            refs.append(String(parts[1]))
        }
        let system = try loadWAV(r.appending(path: "Benchmarks/Fixtures/public/ami/EN2002a/EN2002a.Mix-Headset.wav"), maxSeconds: systemSeconds)
        return Fixture(mic: mic, micReference: refs.joined(separator: " "), system: system)
    }

    /// Records a two-source meeting from the fixture through the real capture path into `store`.
    static func record(_ f: Fixture, store: MeetingStore, speed: Double) async throws -> CaptureResult {
        let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let mic = f.mic, sys = f.system
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: .both),
                                           store: store, title: "Pipeline self-test") { kind in
            let samples = kind == .microphone ? mic : sys
            return SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: fmt, callbackFrames: 512, speed: speed) { i, _ in
                i < samples.count ? samples[Int(i)] : 0
            })
        }
        try session.start()
        _ = await session.waitUntilRecording()
        try await Task.sleep(for: .seconds(Double(max(mic.count, sys.count)) / 16_000 / speed + 0.5))
        return session.stop()
    }

    static func scheduler(store: MeetingStore, client: WorkerClient, hangTimeout: Duration = .seconds(300), notes: Bool = false,
                          processWhileRecording: Bool = false,
                          pressure: @escaping @Sendable () -> JobScheduler.Pressure = { .none }) -> JobScheduler {
        JobScheduler(store: store, executor: WorkerExecutor(client: client, hangTimeout: hangTimeout),
                     configuration: JobScheduler.Configuration(asrConfigHash: PipelineVersions.asr, diarizationConfigHash: PipelineVersions.diarization,
                                                               notesConfigHash: notes ? PipelineVersions.notes : nil,
                                                               concurrentAnalysis: ProcessingModel.concurrentAnalysis,
                                                               processWhileRecording: processWhileRecording),
                     pressure: pressure)
    }

    static func waitForPipeline(_ store: MeetingStore, _ m: MeetingID, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let jobs = (try? store.jobs(meeting: m)) ?? []
            if jobs.contains(where: { $0.key.stage == .reconcile && $0.state == .succeeded }) { return true }
            if jobs.contains(where: { $0.state == .failed && $0.notBefore == nil }) { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    static func report(_ store: MeetingStore, _ m: MeetingID, micReference: String?) -> (ok: Bool, wer: Double?) {
        let log = SelfTest.log
        for j in ((try? store.jobs(meeting: m)) ?? []).sorted(by: { $0.createdAt < $1.createdAt }) {
            log(["step": "job", "stage": j.key.stage.rawValue, "state": j.state.rawValue, "attempts": "\(j.attempt)",
                 "error": j.errorCode ?? "", "seconds": String(format: "%.1f", j.updatedAt.timeIntervalSince(j.createdAt))])
        }
        guard let rev = try? store.meeting(m)?.currentTranscriptRevisionID.flatMap({ try store.transcriptRevision($0) }) else {
            log(["step": "transcript", "error": "none published"]); return (false, nil)
        }
        let micText = rev.allWords.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
        let wer = micReference.map { SimpleWER.wer(reference: $0, hypothesis: micText) }
        log(["step": "transcript", "stage": rev.stage.rawValue, "speakers": "\(rev.speakers.count)",
             "micWords": "\(rev.allWords.filter { $0.source == .microphone }.count)", "systemWords": "\(rev.allWords.filter { $0.source == .systemOutput }.count)",
             "unknownWords": "\(rev.allWords.filter { $0.speaker == .unknown }.count)", "overlapWords": "\(rev.allWords.filter { $0.flags.contains(.overlap) }.count)",
             "micWER": wer.map { String(format: "%.1f%%", $0 * 100) } ?? "-"])
        return (rev.stage == .attributed && rev.speakers.count >= 2 && (wer ?? 0) < 0.10, wer)
    }

    static func endToEnd() async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-pipeline-\(UUID().uuidString)")
            let store = try MeetingStore(root: root)
            let f = try fixture(systemSeconds: 180)
            let t0 = ContinuousClock.now
            let rec = try await record(f, store: store, speed: 20)
            log(["step": "recorded", "segments": "\(rec.segments.count)", "seconds": String(format: "%.0f", rec.segments.map(\.interval.end.seconds).max() ?? 0)])
            let client = WorkerClient()
            let s = scheduler(store: store, client: client, notes: true)
            try s.start()
            try s.enqueuePipeline(rec.meetingID)
            let done = await waitForPipeline(store, rec.meetingID, timeout: .seconds(600))
            log(["step": "pipeline", "completed": "\(done)", "wallSeconds": "\(ContinuousClock.now - t0)"])
            // Notes run in the same worker with the local LLM (ASR/diarization released first).
            var summary: SummaryRevision?
            let deadline = ContinuousClock.now + .seconds(600)
            while summary == nil, ContinuousClock.now < deadline {
                if (try? store.jobs(meeting: rec.meetingID))?.contains(where: { $0.key.stage == .notes && $0.state == .failed }) == true { break }
                summary = try? store.currentSummary(rec.meetingID)
                if summary == nil { try? await Task.sleep(for: .milliseconds(500)) }
            }
            s.stop()
            let r = report(store, rec.meetingID, micReference: f.micReference)
            var notesOK = false
            if let summary, let tr = try store.transcriptRevision(summary.transcriptRevisionID) {
                notesOK = (try? summary.validateReferences(transcript: tr, scratchpad: nil)) != nil
                    && !summary.content.allItems.filter({ $0.kind != .limitation }).isEmpty && !summary.isStale
                log(["step": "notes", "items": "\(summary.content.allItems.filter { $0.kind != .limitation }.count)",
                     "decisions": "\(summary.content.decisions.count)", "actions": "\(summary.content.actionItems.count)",
                     "limitations": "\(summary.content.limitations.count)", "evidenceValid": "\(notesOK)", "producer": summary.producer.component])
            } else {
                log(["step": "notes", "error": "no summary published"])
            }
            return done && r.ok && notesOK
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }

    /// Acceptance (T08): kill the ML worker while a recording is in progress — committed audio continues and the failed
    /// stage retries. Processing is deliberately allowed during recording here (pressure = none) so the worker is busy.
    static func killWorkerWhileRecording() async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-kill-\(UUID().uuidString)")
            let store = try MeetingStore(root: root)
            // Replay at 20×: at 60× under concurrent load the synthetic sources outrun the writer (explicit overrun
            // gaps — correct behaviour, but it degrades the fixture). Real capture runs at 1×.
            let f = try fixture(systemSeconds: 1200)
            let a = try await record(f, store: store, speed: 20)
            log(["step": "recordedA", "segments": "\(a.segments.count)", "missingAudioEvents": "\(a.events.filter(\.isMissingAudio).count)",
                 "finalState": a.finalState.rawValue])
            let client = WorkerClient()
            let s = scheduler(store: store, client: client)
            try s.start()
            try s.enqueuePipeline(a.meetingID)

            // Meeting B records (realtime, synthetic) while A is processed.
            let fmt = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
            let b = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: .microphoneOnly),
                                         store: store, title: "B") { kind in SyntheticSource(kind: kind, plan: .sine(440, format: fmt)) }
            try b.start()
            _ = await b.waitUntilRecording()

            // Wait until A's transcription is under way, then SIGKILL the worker.
            var killedAt: SessionTime?
            for _ in 0..<600 {
                if let j = try store.jobs(meeting: a.meetingID).first(where: { $0.key.stage == .transcribe && $0.state == .running }), j.progress > 0.15,
                   let pid = client.currentWorkerPID {
                    kill(pid, SIGKILL)
                    killedAt = b.now
                    log(["step": "killed", "workerPID": "\(pid)", "transcribeProgress": String(format: "%.2f", j.progress), "recordingBAt": "\(b.now)"])
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let killedAt else { log(["step": "kill", "error": "transcribe never ran"]); return false }
            let done = await waitForPipeline(store, a.meetingID, timeout: .seconds(900))
            try await Task.sleep(for: .seconds(2))
            let rb = b.stop()
            s.stop()
            // B kept recording across the kill: contiguous segments, no missing audio, commits after the kill time.
            let segs = rb.segments.sorted { $0.sequence < $1.sequence }
            let contiguous = zip(segs, segs.dropFirst()).allSatisfy { $0.interval.end == $1.interval.start }
            let after = segs.filter { $0.interval.start > killedAt }.count
            log(["step": "recordingB", "segments": "\(segs.count)", "contiguous": "\(contiguous)", "segmentsAfterKill": "\(after)",
                 "missingAudioEvents": "\(rb.events.filter(\.isMissingAudio).count)", "finalState": rb.finalState.rawValue])
            let transcribe = try store.jobs(meeting: a.meetingID).first { $0.key.stage == .transcribe }
            let windowsDir = root.appending(path: "work/\(a.meetingID.rawValue)").path
            log(["step": "retry", "transcribeAttempts": "\(transcribe?.attempt ?? 0)", "transcribeState": transcribe?.state.rawValue ?? "-",
                 "workDir": windowsDir])
            let r = report(store, a.meetingID, micReference: f.micReference)
            return done && r.ok && contiguous && after > 0 && rb.events.filter(\.isMissingAudio).isEmpty
                && (transcribe?.attempt ?? 0) >= 2 && transcribe?.state == .succeeded
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }
}

extension PipelineSelfTest {
    /// Acceptance (T08, hang half): a job that stops making progress is detected by the heartbeat watchdog, the worker
    /// is killed and recycled, and the job is retried on a fresh worker.
    static func hungWorkerIsRecycled() async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-hang-\(UUID().uuidString)")
            let store = try MeetingStore(root: root)
            let rec = try await record(try fixture(systemSeconds: 60), store: store, speed: 20)
            let client = WorkerClient()
            guard case .pong(let pid1, _)? = try? await client.send(.ping) else { return false }
            _ = try await client.send(.injectFault(.stallNextJob))
            let s = scheduler(store: store, client: client, hangTimeout: .seconds(8))
            try s.start()
            let t0 = ContinuousClock.now
            try s.enqueuePipeline(rec.meetingID)
            let done = await waitForPipeline(store, rec.meetingID, timeout: .seconds(300))
            s.stop()
            let prep = try store.jobs(meeting: rec.meetingID).first { $0.key.stage == .prepare }
            let pid2 = client.currentWorkerPID
            log(["step": "hang", "firstWorkerPID": "\(pid1)", "laterWorkerPID": "\(pid2.map(String.init) ?? "-")",
                 "prepareAttempts": "\(prep?.attempt ?? 0)", "pipelineCompleted": "\(done)", "wall": "\(ContinuousClock.now - t0)"])
            return done && (prep?.attempt ?? 0) >= 2 && pid2 != nil && pid2 != pid1
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }
}

/// Minimal WER for self-test reporting (the full scorer lives in the benchmark target).
enum SimpleWER {
    static func norm(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "-", with: " ").components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .filter { !$0.isEmpty }
    }
    static func wer(reference: String, hypothesis: String) -> Double {
        let r = norm(reference), h = norm(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + [Int](repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) { cur[j] = min(prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1), prev[j] + 1, cur[j - 1] + 1) }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
