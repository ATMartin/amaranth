import Foundation
import Testing
@testable import Diarization
@testable import ASR
import Domain
import Scoring

enum AMI {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let modelDir = repo.appending(path: "ModelStore/speaker-diarization-coreml")
    static var available: Bool { FileManager.default.fileExists(atPath: modelDir.appending(path: "Segmentation.mlmodelc").path) }

    /// Copies an AMI 16 kHz mono WAV into an AnalysisAudio derivative (session-aligned by construction).
    static func derivative(_ meeting: String, to dir: URL) throws -> AnalysisAudio {
        let wav = try Data(contentsOf: repo.appending(path: "Benchmarks/Fixtures/public/ami/\(meeting)/\(meeting).Mix-Headset.wav"))
        // Find the 'data' chunk (AMI headers may contain extra chunks).
        var off = 12
        var dataStart = 44, dataLen = wav.count - 44
        while off + 8 <= wav.count {
            let id = String(decoding: wav[off..<off + 4], as: UTF8.self)
            let len = Int(wav.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)) })
            if id == "data" { dataStart = off + 8; dataLen = min(len, wav.count - dataStart); break }
            off += 8 + len + (len & 1)
        }
        let n = dataLen / 2
        let w = try AnalysisAudio.Writer(url: dir.appending(path: "\(meeting).wav"))
        var i = 0
        while i < n {
            let m = min(160_000, n - i)
            let chunk: [Float] = wav.withUnsafeBytes { raw in
                (0..<m).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: dataStart + (i + $0) * 2, as: Int16.self))) / 32768 }
            }
            try w.write(chunk, at: i)
            i += m
        }
        try w.finish(totalSamples: n)
        return AnalysisAudio(url: dir.appending(path: "\(meeting).wav"))
    }

    static func der(_ result: DiarizationResult, meeting: String) throws -> DER.Result {
        let dir = repo.appending(path: "Benchmarks/Fixtures/public/ami/\(meeting)")
        let ref = DER.parseRTTM(try String(contentsOf: dir.appending(path: "\(meeting).only_words.rttm"), encoding: .utf8))
        let uem = DER.parseUEM(try String(contentsOf: dir.appending(path: "\(meeting).uem"), encoding: .utf8))
        let hyp = result.turns.map { DER.Segment(start: $0.interval.start.seconds, end: $0.interval.end.seconds, speaker: $0.cluster.rawValue) }
        return DER.score(reference: ref, hypothesis: hyp, uem: uem)
    }
}

@Suite("Diarizer on AMI (real model)", .serialized, .enabled(if: AMI.available))
struct DiarizerAMITests {
    @Test(.timeLimit(.minutes(5)))
    func blockwiseLinkingKeepsMeetingWideIdentities() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amr-diar-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for meeting in ["ES2004a", "IS1009a"] {
            let audio = try AMI.derivative(meeting, to: dir)
            let full = try FluidDiarizer(directory: AMI.modelDir, manifestID: ModelManifestID("speaker-diarization-coreml"), revision: "df2625ac")
            var exclusiveOpts = FluidDiarizer.Options(); exclusiveOpts.retainOverlap = false
            let exclusive = try FluidDiarizer(directory: AMI.modelDir, manifestID: ModelManifestID("speaker-diarization-coreml"), revision: "df2625ac", options: exclusiveOpts)
            let re = try await exclusive.analyze(meetingID: MeetingID("m"), source: .systemOutput, audio: audio, cancellation: CancellationToken())
            let dexcl = try AMI.der(re, meeting: meeting)
            print(String(format: "[diar] %@ exclusive (FluidAudio default) DER %.1f%% miss %.0fs", meeting, dexcl.der * 100, dexcl.missed))
            var opts = FluidDiarizer.Options()
            opts.fullFileLimit = 0
            opts.blockSeconds = 300 // force ≥ 3 blocks so cross-block linking is exercised
            let blocked = try FluidDiarizer(directory: AMI.modelDir, manifestID: ModelManifestID("speaker-diarization-coreml"), revision: "df2625ac", options: opts)
            let rf = try await full.analyze(meetingID: MeetingID("m"), source: .systemOutput, audio: audio, cancellation: CancellationToken())
            let rb = try await blocked.analyze(meetingID: MeetingID("m"), source: .systemOutput, audio: audio, cancellation: CancellationToken())
            let df = try AMI.der(rf, meeting: meeting), db = try AMI.der(rb, meeting: meeting)
            print(String(format: "[diar] %@ overlap-retaining full-file DER %.1f%% (miss %.0fs FA %.0fs conf %.0fs, %d spk, %d overlap regions) | 5-min blocks DER %.1f%% (%d spk)",
                         meeting, df.der * 100, df.missed, df.falseAlarm, df.confusion, rf.clusters.count, rf.overlaps.count, db.der * 100, rb.clusters.count))
            #expect(rf.clusters.count == 4)
            #expect(rb.clusters.count <= 6, "linking must not explode identities across blocks")
            #expect(db.der - df.der < 0.10, "blockwise linking costs < 10 DER points")
            #expect(!rf.overlaps.isEmpty)
        }
    }
}

@Suite("Engine call liveness and cancellation")
struct EngineCallTests {
    final class Ticks: @unchecked Sendable {
        private let lock = NSLock(); private var times: [ContinuousClock.Instant] = []
        func add() { lock.withLock { times.append(.now) } }
        var all: [ContinuousClock.Instant] { lock.withLock { times } }
    }

    @Test func ticksStopAtTheBudgetSoAHungCallIsStillDetected() async throws {
        let ticks = Ticks()
        let start = ContinuousClock.now
        let v = try await EngineCall.run(cancellation: CancellationToken(), budget: 1.0, tickEvery: 0.2, tick: { ticks.add() }) {
            try await Task.sleep(for: .seconds(2.5)); return 7
        }
        #expect(v == 7)
        #expect(ticks.all.count >= 3, "ticks flow while within budget")
        #expect(ticks.all.allSatisfy { $0 - start < .seconds(1.15) }, "no ticks after the budget")
    }

    @Test func cancellationStopsACooperativeCallPromptly() async throws {
        let token = CancellationToken()
        let start = ContinuousClock.now
        Task { try await Task.sleep(for: .milliseconds(300)); token.cancel() }
        await #expect(throws: CancellationError.self) {
            _ = try await EngineCall.run(cancellation: token, budget: 60, tick: {}) { () -> Int in
                while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}

@Suite("Diarizer cancellation (real model)", .enabled(if: AMI.available))
struct DiarizerCancellationTests {
    @Test(.timeLimit(.minutes(2)))
    func cancellingMidMeetingStopsWithinSeconds() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amr-diar-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try AMI.derivative("EN2002a", to: dir)   // ~36 min: single full-file engine call
        let diarizer = try FluidDiarizer(directory: AMI.modelDir, manifestID: ModelManifestID("speaker-diarization-coreml"), revision: "df2625ac")
        let token = CancellationToken()
        let cancelAt = ContinuousClock.now + .seconds(2)
        Task { try await Task.sleep(until: cancelAt); token.cancel() }
        await #expect(throws: CancellationError.self) {
            _ = try await diarizer.analyze(meetingID: MeetingID("m"), source: .systemOutput, audio: audio, cancellation: token)
        }
        let lag = ContinuousClock.now - cancelAt
        print("[diar-cancel] stopped \(lag) after cancel (full run takes ~12 s on M2 Max)")
        #expect(lag < .seconds(2), "the engine call stops at its next internal checkpoint")
        // The worker caches the diarizer: after a cancel it must still produce a normal result.
        let again = try await diarizer.analyze(meetingID: MeetingID("m"), source: .systemOutput, audio: try AMI.derivative("IS1009a", to: dir),
                                               cancellation: CancellationToken())
        let der = try AMI.der(again, meeting: "IS1009a")
        #expect(again.clusters.count == 4 && der.der < 0.25, "reused after cancel: \(again.clusters.count) speakers, DER \(der.der)")
    }
}
