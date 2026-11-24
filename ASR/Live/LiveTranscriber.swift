import AVFoundation
public import Foundation
public import Domain
import Capture

/// Provisional live text from committed audio (T14). Stateless per request: it decodes the request's committed CAF
/// segments, places them on the session timeline at 16 kHz, and transcribes from `stableUntil` in single passes
/// (≤ `ParakeetASR.maxInputSeconds`, with 2 s of left context — never FluidAudio's long path).
///
/// Words before the last pause (≥ 0.4 s) that ends at least `settle` seconds before the newest audio become *stable*;
/// later words are *tentative* and are re-decoded next pass. When speech runs on without a pause for over 10 s, the
/// stable point is forced to a word boundary 2 s before the end so latency stays bounded. Final transcripts are
/// produced after Stop by the full pipeline; live words are always shown as provisional. The flush at Stop (`final`)
/// pads the end with silence and settles every word (T20).
public final class LiveTranscriber: @unchecked Sendable {
    let asr: ParakeetASR
    public static let leftContext = 2.0
    public static let settle = 1.5
    public static let forcedAfter = 10.0
    /// Silence appended after the last audio in the flush at Stop, so the final word is decoded whole (T20).
    public static let finalPadding = 1.0

    public init(asr: ParakeetASR) { self.asr = asr }

    public func process(_ r: LiveRequest) async throws -> LiveResponse {
        let segs = r.segments.filter { $0.source == r.source && $0.state == .committed }.sorted { $0.interval.start < $1.interval.start }
        guard let last = segs.last else {
            return LiveResponse(source: r.source, stableWords: [], tentativeWords: [], stableUntil: r.stableUntil, processedUntil: r.stableUntil)
        }
        let origin = max(0, r.stableUntil.seconds - Self.leftContext)
        let end = last.interval.end.seconds
        let limit = end + (r.final ? Self.finalPadding : 0)
        let rate = Double(AnalysisAudio.sampleRate)
        var audio = [Float](repeating: 0, count: max(0, Int((limit - origin) * rate)))
        for seg in segs where seg.interval.end.seconds > origin {
            let decoded = try CAFFile.decode(Data(contentsOf: r.meetingDirectory.appending(path: seg.relativePath)), salvage: true)
            let mono = AnalysisPreparer.downmix(decoded.samples, channels: decoded.format.channelCount, rate: decoded.format.sampleRate)
            let resampled = try Self.resample(mono, from: decoded.format.sampleRate)
            let at = Int((seg.interval.start.seconds - origin) * rate)
            for (i, v) in resampled.enumerated() where at + i >= 0 && at + i < audio.count { audio[at + i] = v }
        }
        // Likely speech from frame energy (100 ms frames, adaptive floor) — the live stand-in for VAD.
        let frame = AnalysisAudio.sampleRate / 10
        let rms: [Float] = stride(from: 0, to: audio.count, by: frame).map { i in
            let s = audio[i..<min(audio.count, i + frame)]
            return (s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))).squareRoot()
        }
        let floor = rms.sorted().prefix(max(1, rms.count / 5)).last ?? 0
        let threshold = max(0.004, floor * 3)
        func speech(_ a: Double, _ b: Double) -> [[Double]] {
            var out: [[Double]] = []
            var start: Double?
            for (i, v) in rms.enumerated() {
                let t = origin + Double(i) * 0.1
                guard t >= a - 0.05, t < b else { continue }
                if v >= threshold { start = start ?? t } else if let s0 = start { out.append([s0, t]); start = nil }
            }
            if let s0 = start { out.append([s0, b]) }
            return out
        }
        /// One single-pass decode of [a, b) with `left` seconds of context; words kept by midpoint.
        func decode(_ a: Double, _ b: Double, left: Double) async throws -> [ParakeetASR.Word] {
            let lo = max(origin, a - left)
            let i0 = Int((lo - origin) * rate), i1 = min(audio.count, Int((b - origin) * rate))
            guard i1 - i0 >= AnalysisAudio.sampleRate / 4 else { return [] }
            return try await asr.transcribe(Array(audio[i0..<i1])).compactMap { w in
                let s = w.start + lo, e = w.end + lo
                let mid = (s + e) / 2
                return mid >= a && mid < b ? ParakeetASR.Word(text: w.text, start: s, end: e, tokenConfidence: w.tokenConfidence) : nil
            }
        }
        /// Decode with the batch pipeline's under-yield guard: Parakeet can skip a whole stretch of clear speech
        /// (asr/0001). If ≥ 2 s of likely speech has no word nearby, re-decode with other contexts, then as two halves,
        /// and keep the best-covered result. Never invents text.
        func window(_ a: Double, _ b: Double) async throws -> [ParakeetASR.Word] {
            let sp = speech(a, b)
            var words = try await decode(a, b, left: Self.leftContext)
            var uncovered = TranscriptionPipeline.uncoveredSpeech(sp, words)
            guard uncovered >= 2 else { return words }
            for left in [0.3, 0.0] {
                let alt = try await decode(a, b, left: left)
                let u = TranscriptionPipeline.uncoveredSpeech(sp, alt)
                if !alt.isEmpty, u < uncovered - 0.25 { words = alt; uncovered = u }
                if uncovered < 2 { return words }
            }
            if b - a > 4 {
                let mid = Self.cut(words, before: (a + b) / 2 + 1, minGap: 0.2) ?? (a + b) / 2
                let split = try await decode(a, mid, left: Self.leftContext) + decode(mid, b, left: Self.leftContext)
                if TranscriptionPipeline.uncoveredSpeech(sp, split) < uncovered - 0.25 { words = split }
            }
            return words
        }
        let maxSpan = ParakeetASR.maxInputSeconds - Self.leftContext
        var stable = r.stableUntil.seconds
        var stableWords: [ParakeetASR.Word] = []
        var tentative: [ParakeetASR.Word] = []
        while end - stable > 0.25 || (r.final && stable < end) {
            let spanEnd = min(limit, stable + maxSpan)
            let words = try await window(stable, spanEnd)
            if spanEnd < limit {
                // More audio than one pass: settle this pass at the last pause before its end (or force near the end).
                let cut = Self.cut(words, before: spanEnd - 1, minGap: 0.3) ?? Self.forcedCut(words, near: spanEnd - 2) ?? spanEnd - 2
                stableWords += words.filter { $0.end <= cut }
                stable = max(cut, stable + 1)
                continue
            }
            if r.final {
                // Nothing more will arrive: every word is settled.
                stableWords += words
                stable = end
            } else if let cut = Self.cut(words, before: end - Self.settle, minGap: 0.4) {
                stableWords += words.filter { $0.end <= cut }
                tentative = words.filter { $0.end > cut }
                stable = cut
            } else if end - stable > Self.forcedAfter, let cut = Self.forcedCut(words, near: end - 2) {
                stableWords += words.filter { $0.end <= cut }
                tentative = words.filter { $0.end > cut }
                stable = cut
            } else {
                tentative = words
            }
            break
        }
        func toDomain(_ w: ParakeetASR.Word) -> Word {
            Word(id: WordID("live-\(r.source.rawValue)-\(Int(w.start * 1000))"), text: w.text, interval: .seconds(w.start, max(w.end, w.start + 0.01)),
                 source: r.source, quality: ASRQuality(engine: "parakeet-tdt-0.6b-v3-live", values: ["tokenConfidenceMean": w.tokenConfidence]))
        }
        return LiveResponse(source: r.source, stableWords: stableWords.map(toDomain), tentativeWords: tentative.map(toDomain),
                            stableUntil: .seconds(stable), processedUntil: .seconds(end))
    }

    /// End of the last inter-word pause of at least `minGap` that ends before `limit` (cut in the middle of the gap).
    static func cut(_ words: [ParakeetASR.Word], before limit: Double, minGap: Double) -> Double? {
        var best: Double?
        for (a, b) in zip(words, words.dropFirst()) where b.start - a.end >= minGap && b.start <= limit { best = (a.end + b.start) / 2 }
        return best
    }

    /// A word boundary nearest to `t` (used when speech has no pause).
    static func forcedCut(_ words: [ParakeetASR.Word], near t: Double) -> Double? {
        words.filter { $0.end <= t }.last.map(\.end)
    }

    static func resample(_ mono: [Float], from rate: Int) throws -> [Float] {
        if rate == AnalysisAudio.sampleRate { return mono }
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AnalysisAudio.sampleRate), channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return [] }
        return try AnalysisPreparer.convert(mono, rate: rate, with: conv, target: outFmt)
    }
}
