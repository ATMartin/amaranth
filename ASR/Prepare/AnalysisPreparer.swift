@preconcurrency import AVFoundation
public import Foundation
public import Domain
import Capture

/// Prepare stage (plan §7): builds one 16 kHz mono analysis derivative per source from immutable committed segments,
/// on the normalized host timeline, plus a coverage map (recorded / paused / missing audio).
///
/// - Downmix: per 100 ms block, channels are averaged unless they are strongly anti-correlated (corr < −0.3), in which
///   case the louder channel is used, so anti-phase content never cancels speech.
/// - Resampling: one AVAudioConverter per epoch (continuous filter state); each segment's output is re-anchored at its
///   normalized start, removing device-clock drift without altering the original samples.
/// - Memory is bounded: segments are streamed one at a time.
public enum AnalysisPreparer {
    public struct Output: Codable, Sendable {
        public var coverage: [SourceCoverage]
        public init(coverage: [SourceCoverage]) { self.coverage = coverage }
    }

    public static func prepare(meetingDirectory: URL, segments: [AudioSegmentRecord], events: [CaptureEvent],
                               outputDirectory: URL, cancellation: CancellationToken? = nil) throws -> Output {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let end = segments.map(\.interval.end).max() ?? .zero
        var out: [SourceCoverage] = []
        for source in SourceKind.allCases {
            let segs = segments.filter { $0.source == source && $0.state == .committed }.sorted { $0.sequence < $1.sequence }
            guard !segs.isEmpty else { continue }
            try cancellation?.check()
            let file = "\(source.rawValue)-16k.wav"
            let total = Int(end.nanoseconds * Int64(AnalysisAudio.sampleRate) / 1_000_000_000)
            try buildDerivative(meetingDirectory: meetingDirectory, segments: segs, to: outputDirectory.appending(path: file),
                                totalSamples: total, cancellation: cancellation)
            out.append(SourceCoverage(source: source, regions: coverage(source: source, segments: segs, events: events, end: end),
                                      derivativeFile: file, duration: end - .zero))
        }
        let result = Output(coverage: out)
        try ContractCoding.encode(result).write(to: outputDirectory.appending(path: "coverage.json"), options: .atomic)
        return result
    }

    static func buildDerivative(meetingDirectory: URL, segments: [AudioSegmentRecord], to url: URL, totalSamples: Int,
                                cancellation: CancellationToken?) throws {
        let builder = try DerivativeBuilder(meetingDirectory: meetingDirectory, url: url)
        for seg in segments {
            try cancellation?.check()
            try builder.append(seg)
        }
        try builder.finish(totalSamples: totalSamples)
        Perf.count("prepare.segments", segments.count)
    }

    /// Builds one source's derivative segment by segment, in sequence order. The batch prepare stage and incremental
    /// processing during recording (T19) both use it, so a derivative built while recording holds exactly the samples
    /// the prepare stage writes for the same segments: placement uses only a segment's own observed start, and the
    /// converter (one per epoch, continuous filter state) sees the same samples in the same order.
    public final class DerivativeBuilder {
        let meetingDirectory: URL
        private let writer: AnalysisAudio.Writer
        private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AnalysisAudio.sampleRate), channels: 1, interleaved: false)!
        private var converter: AVAudioConverter?
        private var converterEpoch: EpochID?
        private var converterRate = 0
        /// Sample index where the last appended segment was placed. A later segment may overwrite from its own start,
        /// which is never much earlier, so samples before this point are settled.
        public private(set) var lastPlacedIndex = 0
        public private(set) var appended = 0

        public init(meetingDirectory: URL, url: URL) throws {
            self.meetingDirectory = meetingDirectory
            writer = try AnalysisAudio.Writer(url: url)
        }

        /// Appends the next segment of the source (in sequence order).
        public func append(_ seg: AudioSegmentRecord) throws {
            let decoded = try Perf.measure("prepare.readSegment") { try CAFFile.decode(Data(contentsOf: meetingDirectory.appending(path: seg.relativePath))) }
            let mono = Perf.measure("prepare.downmix") { downmix(decoded.samples, channels: decoded.format.channelCount, rate: decoded.format.sampleRate) }
            if converterEpoch != seg.epochID || converterRate != decoded.format.sampleRate {
                let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(decoded.format.sampleRate), channels: 1, interleaved: false)!
                converter = AVAudioConverter(from: input, to: target)
                converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                converterEpoch = seg.epochID
                converterRate = decoded.format.sampleRate
            }
            appended += 1
            guard let conv = converter else { return }
            let resampled = try Perf.measure("prepare.resample") { try convert(mono, rate: decoded.format.sampleRate, with: conv, target: target) }
            // Frame 0 is placed at the segment's own observed start: the same with or without later segments known.
            let start = TimelineNormalizer(segments: [seg]).time(segment: seg, frame: 0)
            let index = Int(start.nanoseconds * Int64(AnalysisAudio.sampleRate) / 1_000_000_000)
            try Perf.measure("prepare.write") { try writer.write(resampled, at: index) }
            lastPlacedIndex = index
        }

        public func finish(totalSamples: Int) throws {
            try Perf.measure("prepare.write") { try writer.finish(totalSamples: totalSamples) }
        }
    }

    /// Anti-phase-safe downmix (see type docs).
    static func downmix(_ interleaved: [Float], channels: Int, rate: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var out = [Float](repeating: 0, count: frames)
        let block = max(1, rate / 10)
        var f0 = 0
        while f0 < frames {
            let f1 = min(frames, f0 + block)
            // Correlation and energy of the first two channels decide the policy for this block.
            var sLL: Double = 0, sRR: Double = 0, sLR: Double = 0
            for f in f0..<f1 {
                let l = Double(interleaved[f * channels]), r = Double(interleaved[f * channels + 1])
                sLL += l * l; sRR += r * r; sLR += l * r
            }
            let corr = (sLL > 0 && sRR > 0) ? sLR / (sLL * sRR).squareRoot() : 0
            if corr < -0.3 {
                let pick = sLL >= sRR ? 0 : 1
                for f in f0..<f1 { out[f] = interleaved[f * channels + pick] }
            } else {
                for f in f0..<f1 {
                    var sum: Float = 0
                    for c in 0..<channels { sum += interleaved[f * channels + c] }
                    out[f] = sum / Float(channels)
                }
            }
            f0 = f1
        }
        return out
    }

    static func convert(_ mono: [Float], rate: Int, with conv: AVAudioConverter, target: AVAudioFormat) throws -> [Float] {
        if rate == AnalysisAudio.sampleRate { return mono }
        let input = AVAudioPCMBuffer(pcmFormat: conv.inputFormat, frameCapacity: AVAudioFrameCount(mono.count))!
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * Double(AnalysisAudio.sampleRate) / Double(rate)) + 64
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        let fed = OnceFlag()
        var err: NSError?
        _ = conv.convert(to: output, error: &err) { _, status in
            if !fed.claim() { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return input
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Coverage: segment intervals are recorded; pauses are paused; missing-audio events and anything else uncovered
    /// is missing audio. Regions are merged and sorted.
    static func coverage(source: SourceKind, segments: [AudioSegmentRecord], events: [CaptureEvent], end: SessionTime) -> [CoverageRegion] {
        var regions = segments.map { CoverageRegion(source: source, interval: $0.interval, status: .transcribed) }
        for e in events where e.kind == .pause && (e.source == nil || e.source == source) && !e.interval.isEmpty {
            regions.append(CoverageRegion(source: source, interval: e.interval, status: .paused))
        }
        regions.sort { $0.interval.start < $1.interval.start }
        // Fill holes as missing audio, merge adjacent same-status regions.
        var merged: [CoverageRegion] = []
        var cursor = SessionTime.zero
        for r in regions {
            if r.interval.start > cursor {
                merged.append(CoverageRegion(source: source, interval: SessionInterval(unchecked: cursor, r.interval.start), status: .missingAudio))
            }
            let start = max(cursor, r.interval.start)
            if r.interval.end > start {
                let iv = SessionInterval(unchecked: start, r.interval.end)
                if let last = merged.last, last.status == r.status, last.interval.end == iv.start {
                    merged[merged.count - 1] = CoverageRegion(source: source, interval: SessionInterval(unchecked: last.interval.start, iv.end), status: r.status)
                } else {
                    merged.append(CoverageRegion(source: source, interval: iv, status: r.status))
                }
                cursor = r.interval.end
            }
        }
        if end > cursor { merged.append(CoverageRegion(source: source, interval: SessionInterval(unchecked: cursor, end), status: .missingAudio)) }
        return merged
    }
}

/// One-shot flag for the converter input block (the block may be called on another thread).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    /// Returns true exactly once.
    func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
