import CoreAudio
import Foundation
import CaptureRT
public import Domain

/// Supported capture envelope (plan §6: the format whitelist and memory calculation belong to T03).
/// Formats outside it produce an explicit unsupported-format diagnostic instead of silently downscoping capture.
public enum CaptureFormatPolicy {
    public static let supportedSampleRates: Set<Int> = [16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
    public static let maxChannels = 8
    public static let maxSampleRate = 96_000
    /// Ring capacity in seconds at the maximum supported rate.
    public static let ringSeconds = 2

    public static func validate(_ f: AudioFormat) throws {
        guard f.sampleFormat == .float32, supportedSampleRates.contains(f.sampleRate),
              (1...maxChannels).contains(f.channelCount) else {
            throw AudioSourceError.unsupportedFormat(f)
        }
    }

    /// Ring frames sized for two seconds at the maximum supported rate, so in-envelope rate changes never reallocate.
    public static func ringFrames() -> UInt32 { UInt32(maxSampleRate * ringSeconds) }

    /// Bytes reserved per ring for `channels` (float32).
    public static func ringBytes(channels: Int) -> Int { Int(ringFrames()) * channels * 4 }

    static func format(from asbd: AudioStreamBasicDescription) throws -> AudioFormat {
        let isFloat = asbd.mFormatID == kAudioFormatLinearPCM && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && asbd.mBitsPerChannel == 32
        let f = AudioFormat(sampleRate: Int(asbd.mSampleRate.rounded()), channelCount: Int(asbd.mChannelsPerFrame),
                            sampleFormat: isFloat ? .float32 : .int16,
                            interleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0)
        try validate(f)
        return f
    }
}

/// Owns one C SPSC ring. The producer is the Core Audio IOProc (C); the consumer is the segment writer thread.
public final class RealtimeRing: @unchecked Sendable {
    let raw: OpaquePointer
    public let channels: Int

    public init(channels: Int) {
        precondition((1...CaptureFormatPolicy.maxChannels).contains(channels))
        self.channels = channels
        // ~4 chunks per 10 ms callback over 2 s is ample; chunks are tiny.
        raw = amr_ring_create(UInt32(channels), CaptureFormatPolicy.ringFrames(), 2048)!
    }

    deinit { amr_ring_destroy(raw) }

    var clientData: UnsafeMutableRawPointer { UnsafeMutableRawPointer(raw) }

    func setBufferSelection(first: Int, count: Int) {
        amr_ring_set_buffer_selection(raw, UInt32(first), UInt32(count))
    }

    /// Test/synthetic producer.
    public func pushInterleaved(_ frames: [Float], hostTime: UInt64, sampleTime: Double) {
        frames.withUnsafeBufferPointer {
            amr_ring_push_interleaved(raw, $0.baseAddress, UInt32(frames.count / channels), hostTime, sampleTime)
        }
    }

    public func stats() -> RingStats {
        var s = amr_stats()
        amr_ring_stats(raw, &s)
        let hist = withUnsafeBytes(of: s.histogram) { Array($0.bindMemory(to: UInt64.self)) }
        return RingStats(callbacks: s.callbacks, framesPushed: s.frames_pushed, overrunFrames: s.overrun_frames,
                         overrunEvents: s.overrun_events, formatMismatchCallbacks: s.format_mismatch_callbacks,
                         lastCallbackHostTicks: s.last_callback_host_time, maxCallbackNanos: s.max_callback_ns,
                         histogram: hist)
    }
}

public struct RingStats: Sendable, Hashable {
    public var callbacks: UInt64
    public var framesPushed: UInt64
    public var overrunFrames: UInt64
    public var overrunEvents: UInt64
    public var formatMismatchCallbacks: UInt64
    public var lastCallbackHostTicks: UInt64
    public var maxCallbackNanos: UInt64
    public var histogram: [UInt64]

    /// Callback duration percentile from the histogram (upper bucket edge; 25 µs resolution).
    public func callbackPercentileNanos(_ p: Double) -> UInt64 {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = UInt64((Double(total) * p).rounded(.up))
        var acc: UInt64 = 0
        for (i, c) in histogram.enumerated() {
            acc += c
            if acc >= target { return UInt64(i + 1) * AMR_HIST_BUCKET_NS }
        }
        return UInt64(histogram.count) * AMR_HIST_BUCKET_NS
    }
}

public enum HostClock {
    public static func nowNanos() -> UInt64 { amr_host_now_ns() }
    public static func ticksToNanos(_ t: UInt64) -> UInt64 { amr_host_ticks_to_ns(t) }
}
