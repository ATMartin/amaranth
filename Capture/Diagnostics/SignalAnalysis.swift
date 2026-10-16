public import Foundation
public import Domain

/// Offline analysis of committed segments for capture verification (known-signal tests). Not used in the app's hot path.
public enum SignalAnalysis {
    /// Goertzel power of `hz` in `samples` (mono), in dBFS relative to a full-scale sine.
    public static func toneLevelDB(_ samples: ArraySlice<Float>, hz: Double, sampleRate: Int) -> Double {
        // Missing audio (NaN) contributes nothing; it is reported separately, never treated as signal.
        let valid = samples.filter { !$0.isNaN }
        guard valid.count > 0 else { return -200 }
        let k = 2 * cos(2 * .pi * hz / Double(sampleRate))
        var s1 = 0.0, s2 = 0.0
        for x in valid { let s0 = Double(x) + k * s1 - s2; s2 = s1; s1 = s0 }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        let amplitude = 2 * power.squareRoot() / Double(valid.count)
        return 20 * log10(max(amplitude, 1e-12))
    }

    public static func rmsDB(_ samples: ArraySlice<Float>) -> Double {
        let valid = samples.filter { !$0.isNaN }
        guard !valid.isEmpty else { return -200 }
        let ms = valid.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(valid.count)
        return 10 * log10(max(ms, 1e-24))
    }

    /// A source's committed audio, downmixed to mono, laid out on the session timeline. Missing intervals are NaN
    /// so a gap can never be mistaken for silence.
    public struct Track: Sendable {
        public var sampleRate: Int
        public var samples: [Float]
        public func slice(_ iv: SessionInterval) -> ArraySlice<Float> {
            let a = max(0, min(samples.count, Int(iv.start.seconds * Double(sampleRate))))
            let b = max(a, min(samples.count, Int(iv.end.seconds * Double(sampleRate))))
            return samples[a..<b]
        }
        public var missingFraction: Double { samples.isEmpty ? 1 : Double(samples.filter(\.isNaN).count) / Double(samples.count) }
    }

    public static func track(segments: [AudioSegmentRecord], directory: URL) throws -> Track? {
        guard let first = segments.first else { return nil }
        let rate = first.format.sampleRate
        let end = segments.map(\.interval.end).max()!
        var out = [Float](repeating: .nan, count: Int(end.seconds * Double(rate)) + 1)
        for seg in segments where seg.format.sampleRate == rate {
            let d = try CAFFile.decode(Data(contentsOf: directory.appending(path: seg.relativePath)))
            let ch = d.format.channelCount
            let start = Int((seg.interval.start.seconds * Double(rate)).rounded())
            for f in 0..<d.frameCount where start + f < out.count {
                var sum: Float = 0
                for c in 0..<ch { sum += d.samples[f * ch + c] }
                out[start + f] = sum / Float(ch)
            }
        }
        return Track(sampleRate: rate, samples: out)
    }
}

/// Process resource metrics for capture gates (footprint/CPU).
public enum ProcessMetrics {
    /// Physical footprint in bytes (what Activity Monitor/Instruments report as "Memory").
    public static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Total user+system CPU seconds consumed by this process.
    public static func cpuSeconds() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6 + Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6
    }
}
