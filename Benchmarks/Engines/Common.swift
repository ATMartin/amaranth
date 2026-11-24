@preconcurrency import AVFoundation
import Darwin
import Foundation

/// Engine-neutral word with timing in seconds relative to the input audio.
public struct BenchWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct BenchSpeakerSegment: Codable, Sendable, Hashable {
    public var speaker: String
    public var start: Double
    public var end: Double
}

public enum BenchError: Error, CustomStringConvertible {
    case audio(String), model(String), engine(String)
    public var description: String {
        switch self {
        case .audio(let s): "audio: \(s)"
        case .model(let s): "model: \(s)"
        case .engine(let s): "engine: \(s)"
        }
    }
}

/// Resource measurement for gates: lifetime peak physical footprint includes Metal/ANE allocations attributed to the
/// process on Apple silicon (what Instruments reports as Memory), not only RSS.
public enum ResourceMeter {
    public static func currentFootprint() -> UInt64 {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : 0
    }

    public static func lifetimePeakFootprint() -> UInt64 {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return ok == 0 ? info.ri_lifetime_max_phys_footprint : 0
    }

    public static func cpuSeconds() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6 + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6
    }
}

public func measure<T>(_ body: () async throws -> T) async rethrows -> (T, seconds: Double) {
    let t0 = ContinuousClock.now
    let v = try await body()
    let d = ContinuousClock.now - t0
    return (v, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

/// Audio IO for the harness: decode any AVFoundation-readable file to 16 kHz mono float, cut excerpts, write WAVs.
public enum BenchAudio {
    public static let rate = 16_000

    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw BenchError.audio("no converter") }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * Double(rate) / file.processingFormat.sampleRate) + 1024)
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        var done = false
        while !done {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)!
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                do {
                    try file.read(into: inBuf)
                    if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return inBuf
                } catch { st.pointee = .endOfStream; return nil }
            }
            if let err { throw err }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            if status == .endOfStream || status == .error { done = true }
        }
        return out
    }

    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                              AVLinearPCMIsFloatKey: false],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var offset = 0
        while offset < samples.count {
            let n = min(65_536, samples.count - offset)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + offset, count: n) }
            try file.write(from: buf)
            offset += n
        }
    }

    public static func excerpt(_ s: [Float], start: Double, end: Double) -> [Float] {
        let a = max(0, min(s.count, Int(start * Double(rate)))), b = max(a, min(s.count, Int(end * Double(rate))))
        return Array(s[a..<b])
    }
}

extension ResourceMeter {
    /// System-wide used memory (active + wired + compressor-occupied pages). Captures ANE/GPU-resident model memory
    /// that is not attributed to our process footprint. Noisy: report as a delta against a pre-load baseline.
    public static func systemUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }
}

/// Samples system used memory on a background thread; `peak` is the max seen since `start`.
public final class SystemMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var _peak: UInt64 = 0
    public let baseline: UInt64

    public init(interval: TimeInterval = 0.2) {
        baseline = ResourceMeter.systemUsedBytes()
        _peak = baseline
        Thread.detachNewThread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                let v = ResourceMeter.systemUsedBytes()
                self.lock.withLock { self._peak = max(self._peak, v) }
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    public func stop() -> (baseline: UInt64, peak: UInt64) {
        lock.withLock { running = false }
        return (baseline, lock.withLock { _peak })
    }
}
