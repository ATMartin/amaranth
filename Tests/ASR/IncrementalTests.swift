import Foundation
import Testing
@testable import ASR
import Capture
import Domain
import Scoring

/// Model-free checks of the planning rule incremental processing relies on (T19).
@Suite("Incremental window planning")
struct IncrementalPlanningTests {
    /// Speech regions with gaps of every kind (short pauses, long silences, long unbroken speech), deterministic.
    static func speech(seed: UInt64, until end: Double) -> [(Double, Double)] {
        var x = seed, t = 0.5, out: [(Double, Double)] = []
        func next() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(x >> 11) / Double(1 << 53) }
        while t < end {
            let len = next() < 0.1 ? 15 + next() * 40 : 0.3 + next() * 6
            out.append((t, min(end, t + len)))
            let r = next()
            t += len + (r < 0.5 ? 0.1 + next() * 0.4 : r < 0.85 ? 0.5 + next() * 1.5 : 2 + next() * 30)
        }
        return out
    }

    /// Every window planned from speech known up to a horizon, with the last region still open, is a window of the
    /// full plan, and the plan keeps up with the horizon.
    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func partialPlansArePrefixesOfTheFullPlan(seed: UInt64) {
        let end = 1800.0
        let all = Self.speech(seed: seed, until: end)
        let policy = TranscriptionPipeline.WindowPolicy.default
        let full = TranscriptionPipeline.plan(regions: [(0, end)], merged: TranscriptionPipeline.merge(all), policy: policy)
        var h = 20.0
        while h < end - 30 {
            let merged = TranscriptionPipeline.merge(all.compactMap { $0.0 < h ? ($0.0, min($0.1, h)) : nil })
            let bound = (merged.last?.1).map { ($0 + h) / 2 } ?? h
            let part = TranscriptionPipeline.plan(regions: [(0, .infinity)], merged: merged, policy: policy, settledUntil: bound)
            #expect(Array(full.prefix(part.count)) == part, "seed \(seed), horizon \(h)")
            // Planning lags the horizon by at most a window plus the silence that reaches it.
            let lastSpeech = merged.last?.1 ?? 0
            #expect((part.last?.end ?? 0) >= min(lastSpeech, h) - 2 * policy.maxInput, "seed \(seed), horizon \(h): planned to \(part.last?.end ?? 0)")
            h += 3.7
        }
    }

    @Test func openRegionsListChunksUpToTheFirstOpenOne() {
        let c = TranscriptionPipeline.vadChunks([(0, 700), (710, .infinity)], available: 1900)
        #expect(c.map { [$0.0, $0.1] } == [[0, 600], [595, 700], [710, 1310], [1305, .infinity]])
        #expect(TranscriptionPipeline.vadChunks([(0, .infinity)], available: 10).map { [$0.0, $0.1] } == [[0, .infinity]])
    }
}

@Suite("Incremental transcription (real model)", .serialized, .enabled(if: Replay.modelsAvailable))
struct IncrementalTranscriptionTests {
    static func engines(decoders: Int = 1) throws -> ([ParakeetASR], SileroVAD) {
        (try (0..<decoders).map { _ in try ParakeetASR(directory: Replay.modelStore.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                                                    manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "7dd20fe6") },
         try SileroVAD(modelFile: Replay.modelStore.appending(path: "silero-vad-coreml/silero-vad-unified-256ms-v6.2.1.mlmodelc")))
    }

    /// VAD fed in whole blocks, in several pieces, gives exactly the speech regions of one call over the same samples.
    @Test func streamedVADMatchesWholeChunkVAD() async throws {
        let (speech, _) = try Replay.libriSpeech(count: 6)
        let (_, vad) = try Self.engines()
        let whole = try await vad.speech(speech, padding: TranscriptionPipeline.contextPadding, maxSegment: 14)
        var stream = SileroVAD.Stream()
        var fed = 0
        for piece in [3, 17, 1, 40, 9] where fed < speech.count {
            let n = min(piece * SileroVAD.blockSize, speech.count - fed) / SileroVAD.blockSize * SileroVAD.blockSize
            guard n > 0 else { break }
            try await vad.feed(&stream, Array(speech[fed..<fed + n]))
            fed += n
        }
        try await vad.feed(&stream, Array(speech[fed...]))   // the rest, with the final partial block
        let streamed = await vad.speech(stream, padding: TranscriptionPipeline.contextPadding, maxSegment: 14)
        #expect(whole.count > 5)
        #expect(streamed.map { [$0.0, $0.1] } == whole.map { [$0.0, $0.1] })
    }

    /// The core T19 guarantee: processing while recording, then the normal transcription stage at Stop, gives exactly
    /// the batch transcript, and most windows are not decoded again.
    @Test(.timeLimit(.minutes(10)))
    func incrementalThenStopGivesTheBatchTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-inc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (speech, reference) = try Replay.libriSpeech(count: 24)
        let device = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)   // resampled, downmixed
        let mono = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let up = speech.flatMap { [$0, $0, $0] }
        let delay = 16_000 * 5
        let seconds = Double(speech.count + delay) / 16_000 + 1
        // A pause part-way closes a recorded region; the next region starts its own VAD chunk grid.
        let r = try await Replay.record([.systemOutput: (device, { @Sendable (i: Int64, _: Int) -> Float in i < up.count ? up[Int(i)] : 0 }),
                                         .microphone: (mono, { @Sendable (i: Int64, _: Int) -> Float in
                                             i >= delay && Int(i) - delay < speech.count ? 0.5 * speech[Int(i) - delay] : 0 })],
                                        seconds: seconds, speed: 10, root: root) { s, _ in
            try await Task.sleep(for: .seconds(seconds * 0.4 / 10))
            s.pause()
            try await Task.sleep(for: .seconds(0.3))
            s.resume()
            try await Task.sleep(for: .seconds(seconds * 0.6 / 10))
        }
        #expect(r.events.filter(\.isMissingAudio).isEmpty)
        #expect(r.events.contains { $0.kind == .pause })

        // While recording: segments become visible in commit order, a few seconds at a time.
        let (decoders, vad) = try Self.engines(decoders: 2)
        let incDir = root.appending(path: "incremental")
        let inc = try IncrementalTranscriber(meetingDirectory: r.directory, directory: incDir, decoder: decoders[1], vad: vad)
        let segs = r.segments.sorted { $0.interval.end < $1.interval.end }
        let end = segs.last!.interval.end.seconds
        var finalized: [SourceKind: Double] = [:]
        var words: [SourceKind: [ParakeetASR.Word]] = [:]
        var t = 5.0
        while t < end {
            let visible = segs.filter { $0.interval.end.seconds <= t }
            let events = r.events.filter { $0.interval.end.seconds <= t }
            let p = try #require(try await inc.advance(segments: visible, events: events, deadline: .now + .seconds(60), cancellation: CancellationToken()))
            for s in p.sources {
                #expect(s.finalizedUntil >= finalized[s.source] ?? 0, "finalized text only grows")
                #expect(s.finalizedUntil <= t, "nothing is final before it is recorded")
                finalized[s.source] = s.finalizedUntil
                words[s.source, default: []] += s.newWords
            }
            t += 7
        }
        // Most of the meeting was final before Stop (lag: VAD lookahead plus a window).
        for kind in [SourceKind.systemOutput, .microphone] {
            #expect((finalized[kind] ?? 0) > end - 60, "\(kind): final until \(finalized[kind] ?? 0) of \(end)")
        }

        // Stop: the normal stages, with and without the incremental results.
        let prepDir = root.appending(path: "prep")
        let prepared = try AnalysisPreparer.prepare(meetingDirectory: r.directory, segments: r.segments, events: r.events, outputDirectory: prepDir)
        let batch = try await TranscriptionPipeline(decoders: decoders, vads: [vad], workDirectory: root.appending(path: "batch"))
            .run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: CancellationToken())
        let reusing = TranscriptionPipeline(decoders: decoders, vads: [vad], workDirectory: root.appending(path: "reuse"), incremental: incDir)
        let rev = try await reusing.run(meetingID: r.meetingID, prepared: prepared, preparedDirectory: prepDir, cancellation: CancellationToken())
        func canonical(_ t: TranscriptRevision) -> [String] {
            t.segments.map { seg in "\(seg.source.rawValue)|\(seg.interval)|" + seg.words.map { "\($0.text)@\($0.interval)#\($0.quality.map { "\($0.values)" } ?? "")#\($0.flags.rawValue)" }.joined(separator: " ") }
        }
        #expect(canonical(rev) == canonical(batch), "byte-identical to the batch transcript")
        #expect(rev.coverage == batch.coverage)
        let total = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "batch").path).filter { $0.contains("-w") }.count
        let reused = try #require(reusing.reuse).reusedWindows
        print("[incremental] windows \(total), reused \(reused), VAD chunks reused \(reusing.reuse!.reusedChunks), final until \(finalized), end \(end)")
        #expect(Double(reused) > 0.6 * Double(total))
        // Live text from final windows reads like the final transcript.
        let sys = (words[.systemOutput] ?? []).map(\.text).joined(separator: " ")
        let full = batch.allWords.filter { $0.source == .systemOutput }.map(\.text).joined(separator: " ")
        #expect(full.hasPrefix(sys.prefix(200)))
        #expect(WER.score(reference: reference, hypothesis: full).wer < 0.05)
    }
}
