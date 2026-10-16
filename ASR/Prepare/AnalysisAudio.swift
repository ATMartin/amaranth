public import Foundation
public import Domain

/// 16 kHz mono PCM16 WAV aligned to the session timeline: sample `i` is at session time `i / 16000` s (host timeline).
/// Random access by offset so windows are read without loading a meeting into memory. Derivatives are reproducible
/// from the immutable original segments; they may be deleted and rebuilt.
public struct AnalysisAudio: Sendable {
    public static let sampleRate = 16_000
    public static let headerSize: UInt64 = 44
    public let url: URL

    public init(url: URL) { self.url = url }

    public var sampleCount: Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? Self.headerSize
        return Int((size - min(size, Self.headerSize)) / 2)
    }

    public var duration: SessionDuration { SessionDuration(nanoseconds: Int64(sampleCount) * 1_000_000_000 / Int64(Self.sampleRate)) }

    /// Reads `[start, end)` seconds as float samples (zero-padded past the end).
    public func read(_ interval: SessionInterval) throws -> [Float] {
        let a = max(0, Int(interval.start.nanoseconds * Int64(Self.sampleRate) / 1_000_000_000))
        let b = max(a, Int(interval.end.nanoseconds * Int64(Self.sampleRate) / 1_000_000_000))
        return try read(from: a, count: b - a)
    }

    public func read(from sample: Int, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: Self.headerSize + UInt64(sample) * 2)
        let data = try h.read(upToCount: count * 2) ?? Data()
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let n = data.count / 2
            for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
        }
        return out
    }

    /// Streaming writer with random-access placement; untouched regions read back as zeros.
    final class Writer {
        private let handle: FileHandle
        private(set) var samples = 0

        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Writer.header(samples: 0))
        }

        func write(_ x: [Float], at index: Int) throws {
            guard !x.isEmpty, index >= 0 else { return }
            var d = Data(count: x.count * 2)
            d.withUnsafeMutableBytes { raw in
                for (i, v) in x.enumerated() {
                    let s = Int16(max(-1, min(1, v)) * 32767)
                    raw.storeBytes(of: s.littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
            if index > samples {
                // Zero-fill a gap explicitly (APFS would otherwise leave a hole; explicit zeros keep reads simple).
                try handle.seek(toOffset: AnalysisAudio.headerSize + UInt64(samples) * 2)
                var remaining = index - samples
                let zeros = Data(count: min(remaining, 1 << 18) * 2)
                while remaining > 0 { let n = min(remaining, zeros.count / 2); try handle.write(contentsOf: zeros.prefix(n * 2)); remaining -= n }
            }
            try handle.seek(toOffset: AnalysisAudio.headerSize + UInt64(index) * 2)
            try handle.write(contentsOf: d)
            samples = max(samples, index + x.count)
        }

        /// Pads with zeros to `total` samples, fixes up the header, flushes and closes.
        func finish(totalSamples total: Int) throws {
            if total > samples { try write([0], at: total - 1) }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Writer.header(samples: max(samples, total)))
            try handle.synchronize()
            try handle.close()
        }

        static func header(samples: Int) -> Data {
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            let dataBytes = UInt32(samples * 2)
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(AnalysisAudio.sampleRate))
            u32(UInt32(AnalysisAudio.sampleRate * 2)); u16(2); u16(16)
            d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
            return d
        }
    }
}

/// What a source's derivative contains at each time. Gaps are never presented as silence.
public struct SourceCoverage: Codable, Sendable, Hashable {
    public var source: SourceKind
    public var regions: [CoverageRegion]
    public var derivativeFile: String
    public var duration: SessionDuration

    public init(source: SourceKind, regions: [CoverageRegion], derivativeFile: String, duration: SessionDuration) {
        self.source = source; self.regions = regions; self.derivativeFile = derivativeFile; self.duration = duration
    }

    public func status(at t: SessionTime) -> CoverageRegion.Status {
        regions.first { $0.interval.contains(t) }?.status ?? .missingAudio
    }

    /// Recorded intervals (where ASR/VAD may run).
    public var recorded: [SessionInterval] { regions.filter { $0.status == .transcribed }.map(\.interval) }
}
