import Foundation
import Testing
@testable import ASR
import Capture
import Domain
import Scoring

/// Helpers: record arbitrary signals through the real capture path (synthetic sources), then hand the result to ASR.
enum Replay {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let modelStore = repo.appending(path: "ModelStore")
    static var modelsAvailable: Bool { FileManager.default.fileExists(atPath: modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc").path) }

    /// Records `signals` (per source, at `format`) through RecordingSession at `speed`; pauses/stalls can be scripted.
    static func record(_ signals: [SourceKind: (AudioFormat, @Sendable (Int64, Int) -> Float)], seconds: Double, speed: Double,
                       root: URL, script: ((RecordingSession, [SourceKind: SyntheticSource]) async throws -> Void)? = nil) async throws -> CaptureResult {
        var made: [SourceKind: SyntheticSource] = [:]
        let selection: SourceSelection = signals.count == 2 ? .both : (signals.keys.first == .microphone ? .microphoneOnly : .systemOnly)
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: selection)) { kind in
            let (fmt, sig) = signals[kind]!
            let src = SyntheticSource(kind: kind, plan: SyntheticSource.Plan(format: fmt, callbackFrames: 512, speed: speed, signal: sig))
            made[kind] = src
            return src
        }
        try s.start()
        _ = await s.waitUntilRecording()
        if let script { try await script(s, made) } else { try await Task.sleep(for: .seconds(seconds / speed)) }
        return s.stop()
    }

    /// LibriSpeech utterances (16 kHz) joined with 0.6 s pauses, plus the reference text.
    static func libriSpeech(count: Int) throws -> ([Float], String) {
        let dir = repo.appending(path: "Benchmarks/Results/2026-10-16-t02-run1/inputs")
        let trans = try String(contentsOf: repo.appending(path: "Benchmarks/Fixtures/public/librispeech-test-clean/1089/134686/1089-134686.trans.txt"), encoding: .utf8)
        var samples: [Float] = [], refs: [String] = []
        for line in trans.split(separator: "\n").prefix(count) {
            let parts = line.split(separator: " ", maxSplits: 1)
            let wav = try Data(contentsOf: dir.appending(path: "\(parts[0]).wav"))
            let pcm = wav.dropFirst(44)
            samples += stride(from: 0, to: pcm.count - 1, by: 2).map { i in
                Float(Int16(littleEndian: pcm.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: Int16.self) })) / 32768
            }
            samples += [Float](repeating: 0, count: 9_600)
            refs.append(String(parts[1]))
        }
        return (samples, refs.joined(separator: " "))
    }
}

@Suite("Analysis preparation")
struct PreparerTests {
    @Test func antiPhaseStereoDoesNotCancel() {
        // L = s, R = −s: naive averaging would produce silence.
        let frames = 4_800
        var interleaved: [Float] = []
        for i in 0..<frames { let v = Float(sin(Double(i) * 0.1)) * 0.5; interleaved += [v, -v] }
        let mono = AnalysisPreparer.downmix(interleaved, channels: 2, rate: 48_000)
        let rms = (mono.reduce(0) { $0 + $1 * $1 } / Float(frames)).squareRoot()
        #expect(rms > 0.3, "anti-phase content survives the downmix (rms \(rms))")
        // In-phase content is averaged normally.
        let inPhase = AnalysisPreparer.downmix((0..<frames).flatMap { i -> [Float] in let v = Float(i % 10) / 10; return [v, v] }, channels: 2, rate: 48_000)
        #expect(inPhase[5] == 0.5)
    }

    @Test func derivativeIsTimelineAlignedAndGapsAreNotSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-prep-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fmt = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)
        let r = try await Replay.record([.systemOutput: (fmt, { @Sendable (i: Int64, c: Int) -> Float in Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * (c == 0 ? 0.4 : -0.4) })],
                                        seconds: 0, speed: 1, root: root) { s, sources in
            try await Task.sleep(for: .milliseconds(1500))
            sources[.systemOutput]!.stalled = true
            try await Task.sleep(for: .milliseconds(1500))
            sources[.systemOutput]!.stalled = false
            try await Task.sleep(for: .milliseconds(1500))
        }
        let out = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events,
                                               outputDirectory: root.appending(path: "prep"))
        let cov = try #require(out.coverage.first)
        let audio = AnalysisAudio(url: root.appending(path: "prep").appending(path: cov.derivativeFile))
        let end = r.segments.map(\.interval.end).max()!
        #expect(abs(audio.duration.seconds - end.seconds) < 0.01)
        let missing = cov.regions.filter { $0.status == .missingAudio }
        #expect(missing.contains { $0.interval.duration.seconds > 1.0 }, "the stall is missing audio in coverage, not silence")
        // Recorded region carries the (anti-phase) tone; missing region reads back as zeros but is labelled missing.
        let rec = try #require(cov.regions.first { $0.status == .transcribed && $0.interval.duration.seconds > 0.5 })
        let mid = rec.interval.start + .seconds(0.2)
        let samples = try audio.read(SessionInterval(unchecked: mid, mid + .seconds(0.1)))
        #expect((samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot() > 0.2)
        let gap = try #require(missing.first { $0.interval.duration.seconds > 1.0 })
        #expect(cov.status(at: gap.interval.start + .seconds(0.5)) == .missingAudio)
    }
    @Test func pauseAndSampleRateChangeKeepGlobalTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-prep2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let f48 = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)
        let f44 = AudioFormat(sampleRate: 44_100, channelCount: 1, sampleFormat: .float32)
        let r = try await Replay.record([.systemOutput: (f48, { @Sendable (i: Int64, _: Int) -> Float in 0.3 * Float(sin(Double(i) * 2 * .pi * 300 / 48_000)) })],
                                        seconds: 0, speed: 1, root: root) { s, sources in
            try await Task.sleep(for: .milliseconds(1500))
            s.pause()
            try await Task.sleep(for: .milliseconds(1000))
            s.resume()
            try await Task.sleep(for: .milliseconds(1500))
            let src = sources[.systemOutput]!
            try src.rebuild(format: f44)
            try await Task.sleep(for: .milliseconds(1500))
        }
        let epochs = r.epochs.filter { $0.source == .systemOutput }.sorted { $0.sessionStart < $1.sessionStart }
        #expect(epochs.count >= 3, "start, resume and format-change epochs: \(epochs.map(\.reason))")
        #expect(epochs.contains { $0.format.sampleRate == 44_100 })
        let out = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events,
                                               outputDirectory: root.appending(path: "prep"))
        let cov = try #require(out.coverage.first)
        let audio = AnalysisAudio(url: root.appending(path: "prep").appending(path: cov.derivativeFile))
        // The derivative spans the whole session timeline; the pause is labelled paused (not silence, not speech).
        let end = r.segments.map(\.interval.end).max()!
        #expect(abs(audio.duration.seconds - end.seconds) < 0.01)
        #expect(cov.regions.contains { $0.status == .paused && $0.interval.duration.seconds > 0.5 })
        // Every epoch's audio lands at its session start: energy begins within 30 ms of each epoch start.
        for e in epochs {
            let before = try audio.read(SessionInterval(unchecked: e.sessionStart - .seconds(0.08), e.sessionStart - .seconds(0.03)))
            let after = try audio.read(SessionInterval(unchecked: e.sessionStart + .seconds(0.03), e.sessionStart + .seconds(0.08)))
            func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot() }
            #expect(rms(after) > 0.1, "audio present just after epoch \(e.reason) at \(e.sessionStart.seconds)")
            if e.reason == .resume { #expect(rms(before) < 0.01, "paused audio is not saved") }
        }
        // Sample-count placement is consistent with the session clock: the last epoch's audio ends at the last segment end.
        let tail = try audio.read(SessionInterval(unchecked: end - .seconds(0.1), end - .seconds(0.02)))
        #expect((tail.map { $0 * $0 }.reduce(0, +) / Float(max(tail.count, 1))).squareRoot() > 0.1)
    }
}

@Suite("ASR pipeline logic")
struct ASRLogicTests {
    @Test func garbleDetector() {
        #expect(GarbleDetector.isQuestionable("HORSESENS A DEGERE OF WISDOM THAT KIPS ONE FOM BETTING ON THACSES".split(separator: " ").map(String.init)))
        #expect(GarbleDetector.isQuestionable(Array(repeating: "the", count: 6)))
        #expect(GarbleDetector.isQuestionable("we can we can we can we can we can".split(separator: " ").map(String.init) + ["now"] + Array(repeating: "x", count: 0)) == false)
        #expect(GarbleDetector.isQuestionable(Array(repeating: ["thank", "you", "so"], count: 5).flatMap { $0 }))
        #expect(!GarbleDetector.isQuestionable("The API and AWS bills went up by ten percent this quarter".split(separator: " ").map(String.init)))
        #expect(!GarbleDetector.isQuestionable("HORSE sense a degree of wisdom that keeps one from betting".split(separator: " ").map(String.init)))
    }

    @Test func untranscribedSpeechIsReportedAsFailedCoverage() {
        // A 12 s window with VAD speech 0.5–11.5 s but words only up to 4 s: the rest is not "transcribed".
        let w = TranscriptionPipeline.Window(index: 0, start: 0, end: 12, leftContext: 2, rightContext: 2, speech: [[0.5, 11.5]])
        let words = (0..<8).map { ParakeetASR.Word(text: "w\($0)", start: 0.5 + Double($0) * 0.4, end: 0.8 + Double($0) * 0.4, tokenConfidence: 1) }
        let r = TranscriptionPipeline.WindowResult(window: w, words: words, questionable: false, retried: true,
                                                   uncoveredSpeech: TranscriptionPipeline.uncoveredSpeech(w.speech, words))
        #expect(abs(r.uncoveredSpeech - (11.5 - (3.6 + 0.6))) < 0.01)
        let cov = SourceCoverage(source: .systemOutput, regions: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 12), status: .transcribed)],
                                 derivativeFile: "x.wav", duration: .seconds(12))
        let out = TranscriptionPipeline.coverage(cov, windows: [w], results: [r])
        let failed = out.filter { $0.status == .failed }
        #expect(failed.count == 1)
        #expect(abs(failed[0].interval.start.seconds - 4.2) < 0.01 && abs(failed[0].interval.end.seconds - 11.5) < 0.01)
        #expect(out.contains { $0.status == .transcribed && $0.interval.end.seconds <= 4.21 })
        // Regions tile the window without overlap.
        let total = out.map(\.interval.duration.seconds).reduce(0, +)
        #expect(abs(total - 12) < 0.001)
        // Short misses (< 1 s) are not reported.
        let near = (0..<28).map { ParakeetASR.Word(text: "w", start: 0.5 + Double($0) * 0.4, end: 0.8 + Double($0) * 0.4, tokenConfidence: 1) }
        let r2 = TranscriptionPipeline.WindowResult(window: w, words: near, questionable: false, retried: false)
        #expect(!TranscriptionPipeline.coverage(cov, windows: [w], results: [r2]).contains { $0.status == .failed })
    }

    @Test func productionCodeNeverUsesTheChunkDroppingLongPath() throws {
        // FluidAudio's >15 s path drops chunks (asr/0001); only the benchmark harness may call it.
        for dir in ["ASR/Pipeline", "ASR/Prepare", "InferenceWorker", "App", "Diarization", "Domain"] {
            let root = Replay.repo.appending(path: dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty || dir == "Domain")
            for f in files {
                let text = try String(contentsOf: f, encoding: .utf8)
                #expect(!text.contains("benchmarkOnlyTranscribeLong") && !text.contains("decoderState: &"), "\(f.lastPathComponent) must not use the long path")
            }
        }
    }

    @Test func coverageTilesAcrossWindowsAndSourceGaps() throws {
        // Recorded 0–30 s with a 2 s missing-audio gap; three windows; under-yield in windows 0 and 2 near the boundaries.
        let regions = [CoverageRegion(source: .systemOutput, interval: .seconds(0, 12), status: .transcribed),
                       CoverageRegion(source: .systemOutput, interval: .seconds(12, 14), status: .missingAudio),
                       CoverageRegion(source: .systemOutput, interval: .seconds(14, 30), status: .transcribed)]
        let cov = SourceCoverage(source: .systemOutput, regions: regions, derivativeFile: "x.wav", duration: .seconds(30))
        let w0 = TranscriptionPipeline.Window(index: 0, start: 0, end: 12, leftContext: 2, rightContext: 2, speech: [[1, 12]])
        let w1 = TranscriptionPipeline.Window(index: 1, start: 14, end: 22, leftContext: 2, rightContext: 2, speech: [[14.5, 21.5]])
        let w2 = TranscriptionPipeline.Window(index: 2, start: 22, end: 30, leftContext: 2, rightContext: 2, speech: [[22, 29]])
        func words(_ a: Double, _ b: Double) -> [ParakeetASR.Word] {
            stride(from: a, to: b, by: 0.4).map { ParakeetASR.Word(text: "w", start: $0, end: $0 + 0.3, tokenConfidence: 1) }
        }
        let results = [TranscriptionPipeline.WindowResult(window: w0, words: words(1, 6), questionable: false, retried: true),
                       TranscriptionPipeline.WindowResult(window: w1, words: words(14.5, 21.5), questionable: false, retried: false),
                       TranscriptionPipeline.WindowResult(window: w2, words: words(25, 29), questionable: false, retried: true)]
        let out = TranscriptionPipeline.coverage(cov, windows: [w0, w1, w2], results: results)
        let sorted = out.sorted { $0.interval.start < $1.interval.start }
        #expect(sorted.first?.interval.start == .zero && sorted.last?.interval.end == .seconds(30))
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(a.interval.end == b.interval.start, "contiguous, non-overlapping") }
        #expect(out.filter { $0.status == .failed }.count == 2)
        #expect(out.contains { $0.status == .missingAudio && $0.interval == .seconds(12, 14) })
        // The revision invariant accepts it, and rejects overlapping coverage.
        let rev = TranscriptRevision(meetingID: MeetingID(), kind: .final, stage: .asr, createdAt: Date(),
                                     producer: ProducerInfo(component: "t", configHash: "t"), segments: [], coverage: out)
        try rev.validate()
        var bad = rev
        bad.coverage.append(CoverageRegion(source: .systemOutput, interval: .seconds(5, 6), status: .transcribed))
        #expect(throws: DomainError.self) { try bad.validate() }
    }

    @Test func stitchKeepsTheMoreCentralCopyInOverlaps() {
        typealias W = ParakeetASR.Word
        let w1 = TranscriptionPipeline.WindowResult(window: .init(index: 0, start: 0, end: 14, leftContext: 0.5, rightContext: 1.0),
            words: [W(text: "alpha", start: 12.0, end: 12.4, tokenConfidence: 0.9), W(text: "beta", start: 13.6, end: 13.95, tokenConfidence: 0.5)],
            questionable: false, retried: false)
        let w2 = TranscriptionPipeline.WindowResult(window: .init(index: 1, start: 13.5, end: 27.5, leftContext: 2.0, rightContext: 0.5),
            words: [W(text: "beta", start: 13.62, end: 13.98, tokenConfidence: 0.9), W(text: "gamma", start: 14.2, end: 14.6, tokenConfidence: 0.9)],
            questionable: false, retried: false)
        let out = TranscriptionPipeline.stitch([w1, w2])
        #expect(out.map(\.0.text) == ["alpha", "beta", "gamma"], "no duplicate across the forced split")
        #expect(out[1].1.window.index == 1, "boundary word taken from the window where it is central")
    }
}

@Suite("ASR end to end (real model)", .serialized, .enabled(if: Replay.modelsAvailable))
struct ASREndToEndTests {
    func makePipeline(work: URL) throws -> TranscriptionPipeline {
        let asr = try ParakeetASR(directory: Replay.modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                                  manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "7dd20fe6")
        let vad = try SileroVAD(modelFile: Replay.modelStore.appending(path: "silero-vad-coreml/silero-vad-unified-256ms-v6.2.1.mlmodelc"))
        return TranscriptionPipeline(asr: asr, vad: vad, workDirectory: work)
    }

    @Test(.timeLimit(.minutes(5)))
    func transcribesRecordedSpeechAccuratelyAndResumesFromCheckpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-asr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (speech, reference) = try Replay.libriSpeech(count: 12)
        let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let seconds = Double(speech.count) / 16_000 + 1
        let r = try await Replay.record([.systemOutput: (fmt, { @Sendable (i: Int64, _: Int) -> Float in i < speech.count ? speech[Int(i)] : 0 })], seconds: seconds, speed: 5, root: root)
        // The fixture must reach ASR intact; replay overruns would be reported (explicitly) as capture gaps.
        #expect(r.events.filter(\.isMissingAudio).isEmpty, "replay capture gaps: \(r.events.filter(\.isMissingAudio))")
        let prepDir = root.appending(path: "prep")
        let prepared = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events, outputDirectory: prepDir)

        // First run: cancel part-way through.
        let work = root.appending(path: "asr")
        let pipeline = try makePipeline(work: work)
        let token = CancellationToken()
        let seen = Counter()
        await #expect(throws: CancellationError.self) {
            _ = try await pipeline.run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: token) { _, cp in
                seen.set(cp.completedUnits)
                if cp.completedUnits == 3 { token.cancel() }
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.contains("-w") }
        let checkpointed = files.count
        #expect(checkpointed >= 3)
        func mtimes() throws -> [String: Date] {
            Dictionary(uniqueKeysWithValues: try files.map { ($0, try FileManager.default.attributesOfItem(atPath: work.appending(path: $0).path)[.modificationDate] as! Date) })
        }
        let before = try mtimes()

        // Resume: completed windows are loaded, not re-run; result is complete.
        let t0 = ContinuousClock.now
        let rev = try await pipeline.run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: CancellationToken())
        let resumeTime = ContinuousClock.now - t0
        #expect(try mtimes() == before, "windows checkpointed before the cancel are loaded, not re-decoded")
        // The resumed transcript equals an uninterrupted run from scratch.
        let fresh = try await makePipeline(work: root.appending(path: "asr-fresh")).run(meetingID: r.meetingID, prepared: prepared,
                                                                                         preparedDirectory: prepDir, cancellation: CancellationToken())
        #expect(fresh.allWords.map(\.text) == rev.allWords.map(\.text))
        #expect(fresh.coverage == rev.coverage)
        let hyp = rev.allWords.map(\.text).joined(separator: " ")
        let wer = WER.score(reference: reference, hypothesis: hyp)
        print("[asr-e2e] windows=\(checkpointed)+ WER=\(String(format: "%.1f", wer.wer * 100))% words=\(rev.allWords.count) resume=\(resumeTime)")
        #expect(wer.wer < 0.05)
        #expect(WER.normalize(hyp).prefix(3) == WER.normalize(reference).prefix(3), "opening words preserved")
        #expect(WER.normalize(hyp).suffix(3) == WER.normalize(reference).suffix(3), "closing words preserved (final flush)")
        #expect(rev.coverage.contains { $0.status == .transcribed })
        // Engine guard: inputs beyond one single pass are refused (FluidAudio's internal chunking can drop chunks).
        let asr = try ParakeetASR(directory: Replay.modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                                  manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "x")
        await #expect(throws: ParakeetASR.InputError.self) { _ = try await asr.transcribe([Float](repeating: 0, count: 16_000 * 20)) }
        // Timestamps land on the session timeline (words fall inside recorded audio).
        let end = r.segments.map(\.interval.end).max()!
        #expect(rev.allWords.allSatisfy { $0.interval.end <= end + .seconds(0.6) })
        // Re-running with all checkpoints present is near-instant and identical.
        let again = try await pipeline.run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: CancellationToken())
        #expect(again.allWords.map(\.text) == rev.allWords.map(\.text))
    }

    /// Synthetic speech (macOS `say`, generated at test time) dense with dates, numbers and negations, decoded with
    /// small windows so many cuts fall inside flowing speech: nothing at a boundary may be lost or duplicated.
    @Test(.timeLimit(.minutes(3)))
    func boundariesPreserveNumbersDatesAndNegationsWithoutDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-asr-bnd-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reference = """
            On March third the team did not ship forty two units because the vendor never confirmed the order. \
            We will not accept a delay beyond the fifteenth of April and there is no budget for a second shipment. \
            Please do not approve any invoice above nine thousand five hundred dollars until the twenty first. \
            The meeting moved from seven thirty to eight fifteen and nobody objected to the new time. \
            Sarah said the numbers were never final and the forecast of sixty percent is not guaranteed.
            """
        let wavURL = root.appending(path: "tts.wav")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-r", "200", "-o", wavURL.path, "--data-format=LEI16@16000", reference]
        try say.run(); say.waitUntilExit()
        try #require(say.terminationStatus == 0)
        let speech = try Self.pcm16(wavURL)
        let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let r = try await Replay.record([.systemOutput: (fmt, { @Sendable (i: Int64, _: Int) -> Float in i < speech.count ? speech[Int(i)] : 0 })],
                                        seconds: Double(speech.count) / 16_000 + 1, speed: 5, root: root)
        #expect(r.events.filter(\.isMissingAudio).isEmpty)
        let prepDir = root.appending(path: "prep")
        let prepared = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events, outputDirectory: prepDir)
        var small = TranscriptionPipeline.WindowPolicy(name: "test-8s", silenceContext: 2, pauseContext: 2, forcedLeft: 2, forcedRight: 2, minWindow: 2)
        small.maxInput = 8
        let asr = try ParakeetASR(directory: Replay.modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                                  manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "7dd20fe6")
        let vad = try SileroVAD(modelFile: Replay.modelStore.appending(path: "silero-vad-coreml/silero-vad-unified-256ms-v6.2.1.mlmodelc"))
        for policy in [small, .default] {
            let work = root.appending(path: "asr-\(policy.name)")
            let rev = try await TranscriptionPipeline(asr: asr, vad: vad, workDirectory: work, policy: policy)
                .run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: CancellationToken())
            let windows = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.contains("-w") }.count
            let hyp = rev.allWords.map(\.text).joined(separator: " ")
            let w = WER.score(reference: reference, hypothesis: hyp)
            print("[asr-boundary] \(policy.name) windows=\(windows) WER=\(String(format: "%.1f", w.wer * 100))% numbers \(w.numberTokenErrors)/\(w.numberTokens): \(hyp)")
            if policy == small { #expect(windows >= 6, "the fixture must exercise many boundaries") }
            #expect(w.wer < 0.10, "WER counts number formatting (\"March 3\" for \"March third\") as errors")
            // Every date/number survives, in either written form.
            let lower = hyp.lowercased()
            for fact in [#"march (3|third)"#, #"\b(42|forty[- ]two)\b"#, #"(15th|15|fifteenth) (of )?april"#,
                         #"(9,500|9500|nine thousand five hundred)"#, #"(21st|twenty[- ]first)"#, #"(7[.:]30|seven thirty)"#,
                         #"(8[.:]15|eight fifteen)"#, #"(60|sixty) ?(%|percent)"#] {
                #expect(lower.range(of: fact, options: .regularExpression) != nil, "\(fact) preserved")
            }
            let h = WER.normalize(hyp), ref = WER.normalize(reference)
            for neg in ["not", "never", "no", "nobody"] {
                #expect(h.filter { $0 == neg }.count == ref.filter { $0 == neg }.count, "negation '\(neg)' preserved")
            }
            #expect(!zip(h, h.dropFirst()).contains { $0 == $1 }, "no duplicated words at overlaps")
            #expect(h.prefix(2) == ref.prefix(2) && h.suffix(3) == ref.suffix(3), "opening and closing words")
        }
    }

    /// 16 kHz mono PCM16 WAV (any chunk layout) → floats.
    static func pcm16(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        var off = 12
        while off + 8 <= d.count {
            let id = String(decoding: d[off..<off + 4], as: UTF8.self)
            let size = Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self) })
            if id == "data" {
                let body = d[(off + 8)..<min(d.count, off + 8 + size)]
                return body.withUnsafeBytes { raw in (0..<body.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 } }
            }
            off += 8 + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Live text over a real-time-like sequence of passes: stable words accumulate without duplicates or losses, every
    /// engine input stays single-pass, and the result matches the reference closely.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func liveTranscriberSettlesWordsIncrementally(backlog: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (speech, reference) = try Replay.libriSpeech(count: 6)
        let fmt = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)   // device-like: resampled live
        let up = speech.flatMap { [$0, $0, $0] }
        let r = try await Replay.record([.systemOutput: (fmt, { @Sendable (i: Int64, _: Int) -> Float in i < up.count ? up[Int(i)] : 0 })],
                                        seconds: Double(speech.count) / 16_000 + 1, speed: 10, root: root)
        let asr = try ParakeetASR(directory: Replay.modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                                  manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "7dd20fe6")
        let live = LiveTranscriber(asr: asr)
        // Simulate ticks every 2 s of committed audio.
        let segs = r.segments.sorted { $0.interval.start < $1.interval.start }
        var stable = SessionTime.zero
        var settled: [Word] = []
        var tentative: [Word] = []
        var t = 2.0
        let end = segs.last!.interval.end.seconds
        while t < end + 2 {
            // Backlog variant: no passes for 16 s (as under pressure), then one catch-up pass.
            if backlog, t > 20, t < 36 { t += 2; continue }
            let committed = segs.filter { $0.interval.end.seconds <= t && $0.interval.end.seconds > stable.seconds - 2.5 }
            let resp = try await live.process(LiveRequest(meetingID: r.meetingID, meetingDirectory: r.directory, source: .systemOutput,
                                                          stableUntil: stable, segments: committed))
            settled += resp.stableWords
            tentative = resp.tentativeWords
            #expect(resp.stableUntil >= stable)
            stable = resp.stableUntil
            t += 2
        }
        let all = settled + tentative
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.interval.start <= $1.interval.start }, "time order, no overlap re-emission")
        let wer = WER.score(reference: reference, hypothesis: all.map(\.text).joined(separator: " "))
        print("[live] backlog=\(backlog) settled \(settled.count) tentative \(tentative.count) WER \(String(format: "%.1f", wer.wer * 100))% (S\(wer.substitutions) D\(wer.deletions) I\(wer.insertions))")
        #expect(wer.wer < 0.08)
    }

    @Test(.timeLimit(.minutes(3)))
    func silenceAndToneProduceNoWords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-asr-sil-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fmt = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
        let r = try await Replay.record([.microphone: (fmt, { @Sendable (i: Int64, _: Int) -> Float in i < 48_000 * 20 ? 0 : 0.2 * Float(sin(Double(i) * 2 * .pi * 300 / 48_000)) })],
                                        seconds: 40, speed: 10, root: root)
        let prepDir = root.appending(path: "prep")
        let prepared = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events, outputDirectory: prepDir)
        let rev = try await makePipeline(work: root.appending(path: "asr")).run(meetingID: r.meetingID, prepared: prepared,
                                                                                preparedDirectory: prepDir, cancellation: CancellationToken())
        #expect(rev.allWords.isEmpty, "no fabricated words: \(rev.allWords.map(\.text))")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    func set(_ x: Int) { lock.withLock { v = x } }
    var value: Int { lock.withLock { v } }
}
