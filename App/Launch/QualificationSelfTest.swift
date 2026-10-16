import Foundation
import Capture
import Domain
import ProcessingCore
import Storage

/// T12 `Amaranth --self-test processing-timing --minutes 60|120 --repo <repo> [--self-test-output f.json]`.
/// Records a synthetic two-source meeting (mic: LibriSpeech utterances with pauses; system: AMI meetings looped)
/// through the real capture path at 30×, then processes it end to end (prepare → transcribe → diarize → reconcile →
/// notes) through the real XPC worker twice: **cold** (fresh worker, models not resident) and **warm**. Reports stage
/// times, total time after Stop, peak app/worker footprint, and any network sockets owned by the app or worker.
@MainActor
enum QualificationSelfTest {
    static func processingTiming(minutes: Double, output: URL?) async -> Bool {
        let log = SelfTest.log
        do {
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-timing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(root: root)
            let (mic, sys) = try sources(minutes: minutes)
            log(["step": "fixture", "minutes": "\(minutes)", "micSeconds": "\(mic.count / 16_000)", "systemSeconds": "\(sys.count / 16_000)"])
            let t0 = ContinuousClock.now
            let rec = try await record(mic: mic, sys: sys, store: store, speed: 30)
            log(["step": "recorded", "segments": "\(rec.segments.count)", "missingAudioEvents": "\(rec.events.filter(\.isMissingAudio).count)",
                 "wallSeconds": String(format: "%.0f", (ContinuousClock.now - t0).secondsDouble)])
            var results: [[String: String]] = []
            var ok = rec.events.filter(\.isMissingAudio).isEmpty
            for (label, meeting) in [("cold", rec.meetingID), ("warm", try copyMeeting(rec, store: store))] {
                let client = WorkerClient()
                if label == "cold" { await client.recycle(killWorker: true) }
                guard case .pong(let pid, _)? = try? await client.send(.ping) else { log(["step": label, "worker": "unavailable"]); return false }
                let s = PipelineSelfTest.scheduler(store: store, client: client, notes: true)
                try s.start()
                let start = ContinuousClock.now
                try s.enqueuePipeline(meeting)
                var peakApp: UInt64 = 0, peakWorker: UInt64 = 0, sockets: Set<String> = []
                var done = false
                while ContinuousClock.now - start < .seconds(3 * 3600) {
                    try await Task.sleep(for: .seconds(2))
                    peakApp = max(peakApp, ProcessMetrics.physicalFootprint())
                    peakWorker = max(peakWorker, LiveSelfTest.footprint(pid: pid))
                    sockets.formUnion(networkSockets(pids: [getpid(), pid]))
                    let jobs = try store.jobs(meeting: meeting)
                    if jobs.contains(where: { $0.key.stage == .notes && $0.state == .succeeded }) { done = true; break }
                    if jobs.contains(where: { $0.state == .failed && $0.notBefore == nil }) { break }
                }
                s.stop()
                let total = (ContinuousClock.now - start).secondsDouble
                var row: [String: String] = ["step": label, "completed": "\(done)", "totalSeconds": String(format: "%.0f", total),
                                             "peakAppMiB": String(format: "%.0f", Double(peakApp) / 1_048_576),
                                             "peakWorkerMiB": String(format: "%.0f", Double(peakWorker) / 1_048_576),
                                             "networkSockets": sockets.isEmpty ? "none" : sockets.sorted().joined(separator: "; ")]
                for j in try store.jobs(meeting: meeting) {
                    row["\(j.key.stage.rawValue)Seconds"] = String(format: "%.0f", j.updatedAt.timeIntervalSince(j.createdAt))
                    if j.state != .succeeded { row["\(j.key.stage.rawValue)State"] = "\(j.state.rawValue) \(j.errorCode ?? "")" }
                }
                log(row)
                results.append(row)
                ok = ok && done && sockets.isEmpty
            }
            if let output { try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
            return ok
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }

    /// Mic: LibriSpeech utterances with 2–6 s pauses, looped; system: ES2004a, IS1009a, EN2002a looped. Both `minutes` long.
    static func sources(minutes: Double) throws -> ([Float], [Float]) {
        let r = PipelineSelfTest.repo()
        let n = Int(minutes * 60 * 16_000)
        let inputs = r.appending(path: "Benchmarks/Results/2026-10-16-t02-run1/inputs")
        let trans = try String(contentsOf: r.appending(path: "Benchmarks/Fixtures/public/librispeech-test-clean/1089/134686/1089-134686.trans.txt"), encoding: .utf8)
        var utterances: [[Float]] = []
        for line in trans.split(separator: "\n") {
            let id = line.split(separator: " ", maxSplits: 1)[0]
            if let u = try? PipelineSelfTest.loadWAV(inputs.appending(path: "\(id).wav")) { utterances.append(u) }
        }
        var mic: [Float] = []
        mic.reserveCapacity(n)
        var i = 0
        while mic.count < n {
            mic += utterances[i % utterances.count]
            mic += [Float](repeating: 0, count: 16_000 * (2 + i % 5))
            i += 1
        }
        var sys: [Float] = []
        sys.reserveCapacity(n)
        let meetings = try ["ES2004a", "IS1009a", "EN2002a"].map {
            try PipelineSelfTest.loadWAV(r.appending(path: "Benchmarks/Fixtures/public/ami/\($0)/\($0).Mix-Headset.wav"))
        }
        i = 0
        while sys.count < n { sys += meetings[i % meetings.count]; i += 1 }
        return (Array(mic.prefix(n)), Array(sys.prefix(n)))
    }

    static func record(mic: [Float], sys: [Float], store: MeetingStore, speed: Double) async throws -> CaptureResult {
        let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: .both),
                                           store: store, title: "Timing") { kind in
            let samples = kind == .microphone ? mic : sys
            return SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: fmt, callbackFrames: 1024, speed: speed) { i, _ in
                i < samples.count ? samples[Int(i)] : 0
            })
        }
        try session.start()
        _ = await session.waitUntilRecording()
        try await Task.sleep(for: .seconds(Double(max(mic.count, sys.count)) / 16_000 / speed + 1))
        return session.stop()
    }

    /// A second meeting with the same committed audio (copied files), for the warm run.
    static func copyMeeting(_ r: CaptureResult, store: MeetingStore) throws -> MeetingID {
        let id = MeetingID()
        try store.upsertMeeting(Meeting(id: id, title: "Timing (warm)", createdAt: Date(), captureState: .captured, duration: r.duration))
        try FileManager.default.copyItem(at: store.meetingDirectory(r.meetingID), to: store.meetingDirectory(id))
        var epochMap: [EpochID: EpochID] = [:]
        try store.insertEpochs(r.epochs.map { e in var c = e; c.id = EpochID(); epochMap[e.id] = c.id; c.meetingID = id; return c })
        try store.insertSegments(r.segments.map { s in var c = s; c.id = AudioSegmentID(); c.meetingID = id; c.epochID = epochMap[s.epochID] ?? s.epochID; return c })
        try store.insertEvents(r.events.map { e in var c = e; c.id = CaptureEventID(); c.meetingID = id; return c })
        return id
    }

    /// Internet/UDP sockets owned by `pids` (via lsof). Local XPC/Unix sockets are not network connections.
    static func networkSockets(pids: [Int32]) -> Set<String> {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-i", "-p", pids.map(String.init).joined(separator: ",")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return ["lsof-unavailable"] }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(text.split(separator: "\n").dropFirst().map { String($0.split(separator: " ", omittingEmptySubsequences: true).suffix(3).joined(separator: " ")) })
    }
}

extension Duration {
    var secondsDouble: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
