import CoreAudio
import Foundation
import Testing
import CaptureRT
@testable import Capture
import Domain

@Suite("Realtime ring")
struct RingTests {
    @Test func pushPopRoundTripPreservesSamplesAndTimes() {
        let ring = RealtimeRing(channels: 2)
        let frames = (0..<1000).flatMap { [Float($0), -Float($0)] }
        ring.pushInterleaved(frames, hostTime: 42, sampleTime: 100)
        var chunk = amr_chunk()
        var dst = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES) * 2)
        #expect(dst.withUnsafeMutableBufferPointer { amr_ring_pop(ring.raw, &chunk, $0.baseAddress) })
        #expect(chunk.frame_count == 1000 && chunk.sample_time == 100 && chunk.host_time == 42 && chunk.dropped_frames_before == 0)
        #expect(Array(dst[0..<2000]) == frames)
        #expect(!dst.withUnsafeMutableBufferPointer { amr_ring_pop(ring.raw, &chunk, $0.baseAddress) })
    }

    @Test func largeBuffersAreSplitIntoBoundedChunks() {
        let ring = RealtimeRing(channels: 1)
        ring.pushInterleaved((0..<10_000).map(Float.init), hostTime: 0, sampleTime: 0)
        var chunk = amr_chunk()
        var dst = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES))
        var sizes: [UInt32] = [], starts: [Double] = []
        while dst.withUnsafeMutableBufferPointer({ amr_ring_pop(ring.raw, &chunk, $0.baseAddress) }) {
            sizes.append(chunk.frame_count); starts.append(chunk.sample_time)
        }
        #expect(sizes == [4096, 4096, 1808])
        #expect(starts == [0, 4096, 8192])
    }

    @Test func overrunIsCountedAndAttachedToNextChunk() {
        let ring = RealtimeRing(channels: 1)
        let cap = Int(CaptureFormatPolicy.ringFrames())
        let block = [Float](repeating: 0.5, count: 4000)
        var pushed = 0
        while pushed + 4000 <= cap { ring.pushInterleaved(block, hostTime: 0, sampleTime: Double(pushed)); pushed += 4000 }
        ring.pushInterleaved(block, hostTime: 0, sampleTime: Double(pushed)) // does not fit → dropped
        var s = ring.stats()
        #expect(s.overrunFrames == 4000 && s.overrunEvents == 1)
        // Drain one chunk to make room, then push: the new chunk reports the earlier drop.
        var chunk = amr_chunk()
        var dst = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES))
        _ = dst.withUnsafeMutableBufferPointer { amr_ring_pop(ring.raw, &chunk, $0.baseAddress) }
        ring.pushInterleaved(block, hostTime: 0, sampleTime: Double(pushed + 4000))
        var last = amr_chunk()
        while dst.withUnsafeMutableBufferPointer({ amr_ring_pop(ring.raw, &chunk, $0.baseAddress) }) { last = chunk }
        #expect(last.dropped_frames_before == 4000)
        s = ring.stats()
        #expect(s.framesPushed == UInt64(pushed + 4000))
    }

    @Test func nonInterleavedBuffersAreInterleaved() {
        let ring = RealtimeRing(channels: 2)
        var left: [Float] = [1, 2, 3], right: [Float] = [-1, -2, -3]
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                let abl = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(abl.unsafeMutablePointer) }
                abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: l.baseAddress)
                abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: r.baseAddress)
                var ts = AudioTimeStamp()
                ts.mFlags = [.sampleTimeValid, .hostTimeValid]
                ts.mSampleTime = 7
                amr_ring_push(ring.raw, abl.unsafePointer, &ts)
            }
        }
        var chunk = amr_chunk()
        var dst = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES) * 2)
        #expect(dst.withUnsafeMutableBufferPointer { amr_ring_pop(ring.raw, &chunk, $0.baseAddress) })
        #expect(Array(dst[0..<6]) == [1, -1, 2, -2, 3, -3])
        #expect(chunk.sample_time == 7)
    }

    @Test func channelMismatchIsCountedNotWritten() {
        let ring = RealtimeRing(channels: 2)
        var mono: [Float] = [1, 2, 3]
        mono.withUnsafeMutableBytes { m in
            let abl = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(abl.unsafeMutablePointer) }
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 12, mData: m.baseAddress)
            amr_ring_push(ring.raw, abl.unsafePointer, nil)
        }
        #expect(ring.stats().formatMismatchCallbacks == 1)
        #expect(amr_ring_buffered_frames(ring.raw) == 0)
    }

    @Test func percentileFromHistogram() {
        var h = [UInt64](repeating: 0, count: Int(AMR_HIST_BUCKETS))
        h[0] = 98; h[3] = 1; h[10] = 1
        let s = RingStats(callbacks: 100, framesPushed: 0, overrunFrames: 0, overrunEvents: 0, formatMismatchCallbacks: 0,
                          lastCallbackHostTicks: 0, maxCallbackNanos: 0, histogram: h)
        #expect(s.callbackPercentileNanos(0.5) == 25_000)
        #expect(s.callbackPercentileNanos(0.99) == 100_000)
    }

    @Test func formatWhitelistAndMemory() throws {
        try CaptureFormatPolicy.validate(AudioFormat(sampleRate: 44_100, channelCount: 2, sampleFormat: .float32))
        #expect(throws: AudioSourceError.self) {
            try CaptureFormatPolicy.validate(AudioFormat(sampleRate: 192_000, channelCount: 2, sampleFormat: .float32))
        }
        #expect(throws: AudioSourceError.self) {
            try CaptureFormatPolicy.validate(AudioFormat(sampleRate: 48_000, channelCount: 16, sampleFormat: .float32))
        }
        // Worst case ring: 2 s × 96 kHz × 8 ch × 4 B.
        #expect(CaptureFormatPolicy.ringBytes(channels: 8) == 6_144_000)
        #expect(CaptureFormatPolicy.ringBytes(channels: 2) == 1_536_000)
    }
}

@Suite("CAF codec")
struct CAFTests {
    @Test func roundTrip() throws {
        let f = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)
        let samples: [Float] = (0..<9600).map { sin(Float($0) * 0.01) }
        let data = samples.withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: f) }
        #expect(data.count == CAFFile.headerSize + samples.count * 4)
        let d = try CAFFile.decode(data)
        #expect(d.format == f && d.samples == samples && d.frameCount == 4800)
    }

    @Test func truncatedFileIsDetected() throws {
        let f = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        let data = [Float](repeating: 0.1, count: 1000).withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: f) }
        #expect(throws: CAFFile.DecodeError.truncated(expected: 4000, actual: 3000)) { _ = try CAFFile.decode(data.prefix(CAFFile.headerSize + 3000)) }
    }

    @Test func systemCanReadOurCAF() throws {
        // AudioToolbox must accept the file (afinfo-level compatibility), not just our own decoder.
        let f = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
        let data = [Float](repeating: 0.25, count: 48_000).withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: f) }
        let url = FileManager.default.temporaryDirectory.appending(path: "amr-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/afinfo")
        p.arguments = [url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0)
        #expect(text.contains("48000 Hz") && text.contains("1.000000 sec"), "\(text)")
    }
}
