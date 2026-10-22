import Foundation
import Capture
import CryptoKit
import Domain
import ProcessingCore
import Storage

/// T16 `Amaranth --self-test perf-run --perf-spec <spec.json> [--self-test-output f.jsonl]`, driven by
/// `amaranth-bench perf-suite`. Each item is replayed through the real capture path (or copied from an Amaranth
/// library copy) into a private temporary store, then processed through the real XPC worker and `JobScheduler`.
/// Writes per-run outputs and timings (see `PerfRun`) and never touches the user's library.
@MainActor
enum PerfSelfTest {
    static func run(specURL: URL) async -> Bool {
        let log = SelfTest.log
        do {
            let spec = try ContractCoding.decode(PerfRun.Spec.self, from: Data(contentsOf: specURL))
            let out = URL(filePath: spec.outputDirectory)
            let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-perf-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try MeetingStore(root: root)
            let cache = try spec.captureCache.map { try CaptureCache(root: URL(filePath: $0)) }
            let client = WorkerClient()
            var ok = true
            for item in spec.items {
                log(["step": "item", "id": item.id, "kind": item.kind.rawValue])
                do {
                    let (meeting, recording) = try await ingest(item, store: store, cache: cache, speed: spec.speed)
                    // The warm copy is made before processing so both runs see identical committed inputs.
                    var runs = [(item.coldWorker ? "cold" : "default", meeting)]
                    if item.repeatWarm { runs.append(("warm", try copyMeeting(meeting, from: store, to: store))) }
                    for (label, m) in runs {
                        if label == "cold" { await killWorker(client) }
                        var r = try await process(m, item: item, label: label, store: store, client: client)
                        r.recordWallSeconds = recording?.wall
                        r.missingAudioEvents = recording?.missing ?? 0
                        if r.missingAudioEvents > 0 { r.completed = false; r.failure = "missing audio during replay" }
                        let dir = out.appending(path: item.id).appending(path: label)
                        try writeOutputs(r, meeting: m, store: store, to: dir)
                        log(["step": "done", "id": item.id, "run": label, "completed": "\(r.completed)",
                             "stopToTranscript": r.stopToTranscriptSeconds.map { String(format: "%.1f", $0) } ?? "-",
                             "stopToNotes": r.stopToNotesSeconds.map { String(format: "%.1f", $0) } ?? "-", "failure": r.failure ?? ""])
                        ok = ok && r.completed
                    }
                } catch {
                    log(["step": "error", "id": item.id, "error": "\(error)"])
                    ok = false
                }
            }
            return ok
        } catch {
            log(["step": "error", "error": "\(error)"])
            return false
        }
    }

    // MARK: Ingest

    struct Recording: Codable { var wall: Double; var missing: Int }

    /// Replayed captures kept between runs (see `PerfRun.Spec.captureCache`), keyed by item ID and the SHA-256 of each
    /// raw input (perf-suite rewrites the inputs every run, so size and modification time are not stable), so a
    /// changed input is captured again.
    struct CaptureCache {
        struct Entry: Codable { var key: String; var meetingID: String; var recording: Recording }
        let store: MeetingStore
        let index: URL

        init(root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try MeetingStore(root: root)
            index = root.appending(path: "captures.json")
        }

        static func key(_ item: PerfRun.Item) -> String {
            let inputs = [item.system, item.microphone].map { a -> String in a.flatMap { sha256(path: $0.path) } ?? "-" }
            return ([item.id] + inputs).joined(separator: "|")
        }

        static func sha256(path: String) -> String? {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            var hash = SHA256()
            while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func entries() -> [String: Entry] {
            ((try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: index))) ?? []).reduce(into: [:]) { $0[$1.key] = $1 }
        }

        func lookup(_ item: PerfRun.Item) -> Entry? {
            guard let e = entries()[Self.key(item)], (try? store.meeting(MeetingID(e.meetingID))) != nil else { return nil }
            return e
        }

        func save(_ e: Entry) throws {
            var all = entries()
            all[e.key] = e
            try JSONEncoder().encode(all.values.sorted { $0.key < $1.key }).write(to: index, options: .atomic)
        }
    }

    static func ingest(_ item: PerfRun.Item, store: MeetingStore, cache: CaptureCache?, speed: Double) async throws -> (MeetingID, Recording?) {
        switch item.kind {
        case .audio:
            if let cache, let e = cache.lookup(item) {
                return (try copyMeeting(MeetingID(e.meetingID), from: cache.store, to: store), e.recording)
            }
            let sys = try item.system.map(MappedAudio.init), mic = try item.microphone.map(MappedAudio.init)
            let t0 = ContinuousClock.now
            let r = try await record(system: sys, microphone: mic, store: cache?.store ?? store, title: item.id, speed: speed)
            let rec = Recording(wall: Perf.seconds(since: t0), missing: r.events.filter(\.isMissingAudio).count)
            guard let cache else { return (r.meetingID, rec) }
            // Only a clean capture is reused; a replay with missing audio is reported and captured again next time.
            if rec.missing == 0 { try cache.save(.init(key: CaptureCache.key(item), meetingID: r.meetingID.rawValue, recording: rec)) }
            return (try copyMeeting(r.meetingID, from: cache.store, to: store), rec)
        case .amaranthMeeting:
            guard let lib = item.library, let id = item.meetingID else { throw CocoaError(.fileReadInvalidFileName) }
            let source = try MeetingStore(root: URL(filePath: lib))
            return (try copyMeeting(MeetingID(id), from: source, to: store), nil)
        case .notesTranscript:
            guard let path = item.transcript else { throw CocoaError(.fileReadInvalidFileName) }
            var tr = try ContractCoding.decode(TranscriptRevision.self, from: Data(contentsOf: URL(filePath: path)))
            let m = MeetingID()
            tr.meetingID = m
            let end = tr.coverage.map(\.interval.end).max() ?? .zero
            try store.upsertMeeting(Meeting(id: m, title: item.id, createdAt: Date(), captureState: .captured, duration: end - .zero))
            try store.insertTranscriptRevision(tr)
            try store.publishTranscript(tr)
            return (m, nil)
        }
    }

    /// Raw interleaved float32 audio, memory-mapped (file-backed, so it does not inflate the app's footprint).
    final class MappedAudio: @unchecked Sendable {
        let format: AudioFormat
        let frames: Int
        private let base: UnsafePointer<Float>
        private let length: Int

        init(_ a: PerfRun.RawAudio) throws {
            let fd = open(a.path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(.ENOENT) }
            defer { close(fd) }
            var st = stat()
            fstat(fd, &st)
            length = Int(st.st_size)
            guard length > 0, let p = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { throw POSIXError(.EIO) }
            base = UnsafePointer(p.assumingMemoryBound(to: Float.self))
            format = AudioFormat(sampleRate: a.sampleRate, channelCount: a.channels, sampleFormat: .float32)
            frames = length / 4 / a.channels
        }

        deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }

        func sample(_ frame: Int64, _ channel: Int) -> Float {
            frame < frames ? base[Int(frame) * format.channelCount + channel] : 0
        }
    }

    static func record(system: MappedAudio?, microphone: MappedAudio?, store: MeetingStore, title: String, speed: Double) async throws -> CaptureResult {
        let selection: SourceSelection = system != nil && microphone != nil ? .both : system != nil ? .systemOnly : .microphoneOnly
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: store.root, options: RecordingOptions(selection: selection),
                                           store: store, title: title) { kind in
            let audio = (kind == .microphone ? microphone : system)!
            return SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: audio.format, callbackFrames: 1024, speed: speed) { i, c in
                audio.sample(i, c)
            })
        }
        try session.start()
        _ = await session.waitUntilRecording()
        let seconds = [system, microphone].compactMap { $0.map { Double($0.frames) / Double($0.format.sampleRate) } }.max() ?? 0
        try await Task.sleep(for: .seconds(seconds / speed + 1))
        return session.stop()
    }

    /// Copies a captured meeting (rows and committed audio files) between stores, or within one store.
    static func copyMeeting(_ id: MeetingID, from source: MeetingStore, to target: MeetingStore) throws -> MeetingID {
        guard var meeting = try source.meeting(id) else { throw CocoaError(.fileNoSuchFile) }
        let new = MeetingID()
        meeting.id = new
        meeting.currentTranscriptRevisionID = nil
        meeting.currentSummaryRevisionID = nil
        try target.upsertMeeting(meeting)
        try FileManager.default.copyItem(at: source.meetingDirectory(id), to: target.meetingDirectory(new))
        var epochMap: [EpochID: EpochID] = [:]
        try target.insertEpochs(try source.epochs(id).map { e in var c = e; c.id = EpochID(); epochMap[e.id] = c.id; c.meetingID = new; return c })
        try target.insertSegments(try source.segments(id).map { s in
            var c = s; c.id = AudioSegmentID(); c.meetingID = new; c.epochID = epochMap[s.epochID] ?? s.epochID; return c
        })
        try target.insertEvents(try source.events(id).map { e in var c = e; c.id = CaptureEventID(); c.meetingID = new; return c })
        return new
    }

    static func killWorker(_ client: WorkerClient) async {
        _ = try? await client.send(.ping)   // learn the PID so recycle can kill it
        client.recycle(killWorker: true)
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: Process

    static func process(_ m: MeetingID, item: PerfRun.Item, label: String, store: MeetingStore, client: WorkerClient) async throws -> PerfRun.ItemResult {
        guard case .pong(let pid, _)? = try? await client.send(.ping) else { throw CocoaError(.executableLoad) }
        let thermalStart = ProcessInfo.processInfo.thermalState.label
        let s = PipelineSelfTest.scheduler(store: store, client: client, hangTimeout: .seconds(1800), notes: item.notes)
        try s.start()
        defer { s.stop() }
        let t0 = Date()
        if item.kind == .notesTranscript { try s.enqueueNotes(m) } else { try s.enqueuePipeline(m) }
        var peakApp: UInt64 = 0, peakWorker: UInt64 = 0, pids: [Int32] = [pid]
        var completed = false, failure: String?
        let deadline = ContinuousClock.now + .seconds(4 * 3600)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if case .connected(let p) = client.state, !pids.contains(p) { pids.append(p) }
            peakApp = max(peakApp, ProcessMetrics.physicalFootprint())
            peakWorker = max(peakWorker, pids.map { LiveSelfTest.footprint(pid: $0) }.max() ?? 0)
            let jobs = try store.jobs(meeting: m)
            func succeeded(_ st: ProcessingStage) -> Bool { jobs.contains { $0.key.stage == st && $0.state == .succeeded } }
            if let f = jobs.first(where: { $0.state == .failed && $0.notBefore == nil }) { failure = "\(f.key.stage.rawValue): \(f.errorCode ?? "")"; break }
            if item.kind == .notesTranscript ? succeeded(.notes) : succeeded(.reconcile) && (!item.notes || succeeded(.notes)) { completed = true; break }
        }
        if !completed && failure == nil { failure = "timeout" }
        var stages: [PerfRun.StageResult] = []
        for j in try store.jobs(meeting: m).sorted(by: { $0.createdAt < $1.createdAt }) {
            let dir = store.root.appending(path: "work").appending(path: m.rawValue).appending(path: "\(j.key.stage.rawValue)-\(j.key.inputHash.prefix(12))")
            stages.append(PerfRun.StageResult(stage: j.key.stage.rawValue, state: j.state.rawValue, errorCode: j.errorCode,
                                              scheduler: try? ContractCoding.decode(SchedulerTiming.self, from: Data(contentsOf: dir.appending(path: SchedulerTiming.fileName))),
                                              worker: try? ContractCoding.decode(StageTiming.self, from: Data(contentsOf: dir.appending(path: StageTiming.fileName)))))
        }
        func finished(_ st: String) -> Double? {
            stages.last { $0.stage == st && $0.state == "succeeded" }?.scheduler.map { $0.finishedAt - t0.timeIntervalSince1970 }
        }
        let audio = try store.segments(m).map(\.interval.end.seconds).max() ?? 0
        return PerfRun.ItemResult(id: item.id, run: label, completed: completed, failure: failure, audioSeconds: audio, recordWallSeconds: nil,
                                  missingAudioEvents: 0, stopToTranscriptSeconds: finished("reconcile"), stopToNotesSeconds: finished("notes"),
                                  stages: stages, peakAppMiB: Double(peakApp) / 1_048_576, peakWorkerMiB: Double(peakWorker) / 1_048_576,
                                  workerPIDs: pids, thermalStart: thermalStart, thermalEnd: ProcessInfo.processInfo.thermalState.label)
    }

    static func writeOutputs(_ r: PerfRun.ItemResult, meeting m: MeetingID, store: MeetingStore, to dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func put<T: Codable & Sendable>(_ v: T?, _ name: String) throws {
            if let v { try ContractCoding.encode(v).write(to: dir.appending(path: name), options: .atomic) }
        }
        try put(r, "result.json")
        try put(try store.transcriptRevisions(m).last { $0.stage == .asr }, "asr.json")
        try put(try store.meeting(m)?.currentTranscriptRevisionID.flatMap { try store.transcriptRevision($0) }, "transcript.json")
        try put(try store.currentSummary(m), "summary.json")
        if let d = try store.jobs(meeting: m, states: [.succeeded]).last(where: { $0.key.stage == .diarize }), let ref = d.outputRef,
           case .diarization(let out) = try StageFiles.read(StageOutput.self, from: store.root.appending(path: ref)).0 {
            try put(out.results, "diarization.json")
        }
    }
}
