import Foundation
import Testing
@testable import Diarization
@testable import ASR

/// Acoustic delay between system audio and its echo in the mic, on synthetic speech-like bursts.
@Suite("Echo delay")
struct EchoAnalyzerTests {
    /// Speech-like signal: noise bursts of random length separated by pauses (deterministic seed).
    static func bursts(seconds: Double, seed: UInt64) -> [Float] {
        var rng = seed
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        var out: [Float] = []
        let total = Int(seconds * 16_000)
        while out.count < total {
            let on = Int((0.2 + next() * 1.2) * 16_000), off = Int((0.1 + next() * 0.6) * 16_000)
            out += (0..<on).map { _ in Float(next() * 2 - 1) * 0.3 }
            out += [Float](repeating: 0, count: off)
        }
        return Array(out.prefix(total))
    }

    static func write(_ x: [Float], to url: URL) throws -> AnalysisAudio {
        let w = try AnalysisAudio.Writer(url: url)
        try w.write(x, at: 0)
        try w.finish(totalSamples: x.count)
        return AnalysisAudio(url: url)
    }

    @Test func findsTheEchoDelayAndRejectsUnrelatedAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amr-echo-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = Self.bursts(seconds: 60, seed: 1)
        let local = Self.bursts(seconds: 60, seed: 2)
        for delay in [0.06, 0.18, 0.35] {
            let d = Int(delay * 16_000)
            // Mic = attenuated delayed echo + quieter local talker (speech during remote playback).
            let mic = (0..<system.count).map { i in (i >= d ? 0.35 * system[i - d] : 0) + 0.15 * local[i] }
            let est = try EchoAnalyzer.estimateDelay(mic: Self.write(mic, to: dir.appending(path: "mic-\(d).wav")),
                                                     system: Self.write(system, to: dir.appending(path: "sys.wav")))
            let e = try #require(est, "echo at \(delay) s must be found")
            #expect(abs(e - delay) <= 0.015, "estimated \(e) for true \(delay)")
        }
        // No echo path: unrelated audio gives no delay rather than a spurious one.
        let none = try EchoAnalyzer.estimateDelay(mic: Self.write(local, to: dir.appending(path: "local.wav")),
                                                  system: Self.write(system, to: dir.appending(path: "sys2.wav")))
        #expect(none == nil)
        // Too short to judge: nil.
        #expect(try EchoAnalyzer.estimateDelay(mic: Self.write(Array(local.prefix(16_000 * 3)), to: dir.appending(path: "s.wav")),
                                               system: Self.write(Array(system.prefix(16_000 * 3)), to: dir.appending(path: "s2.wav"))) == nil)
    }
}
