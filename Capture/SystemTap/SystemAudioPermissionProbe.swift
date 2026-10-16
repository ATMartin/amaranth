import AVFoundation
import CoreAudio
import Foundation
import CaptureRT
import Domain

/// Public-API probe for system-audio capture permission (no private TCC SPI).
///
/// Taps only Amaranth's own output with `muteBehavior = .muted` (so the probe is inaudible), plays a short tone
/// through AVAudioEngine, and checks whether non-zero samples arrive. When system-audio capture is denied, a tap
/// delivers silence, so "no signal from a known-playing source" ⇒ denied. The first call may show the system prompt.
public enum SystemAudioPermissionProbe {
    public enum Result: String, Sendable {
        case granted
        /// The known tone did not arrive: capture is denied (or blocked by policy).
        case denied
        /// The probe itself could not run (e.g. no output device); permission state is unknown.
        case unavailable
    }

    public static func run(timeout: Duration = .milliseconds(1500)) async -> (Result, String) {
        // 1. Make Amaranth an active audio client playing a tone.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000) else { return (.unavailable, "buffer") }
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do { try engine.start() } catch { return (.unavailable, "engine \(error)") }
        defer { engine.stop() }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()

        // 2. Muted private tap of our own (now playing) process only.
        var selfObject = AudioObjectID(kAudioObjectUnknown)
        for _ in 0..<25 {
            selfObject = (try? HAL.translatePIDToProcessObject(getpid())) ?? AudioObjectID(kAudioObjectUnknown)
            if selfObject != kAudioObjectUnknown { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard selfObject != kAudioObjectUnknown else { return (.unavailable, "no process object") }
        let desc = CATapDescription(stereoMixdownOfProcesses: [selfObject])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .muted
        desc.name = "Amaranth permission probe"
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != kAudioObjectUnknown else { return (.unavailable, "createTap") }
        defer { AudioHardwareDestroyProcessTap(tap) }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Amaranth Probe",
            kAudioAggregateDeviceUIDKey: SystemAudioTapSource.aggregateUIDPrefix + "probe." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr else { return (.unavailable, "createAggregate") }
        defer { AudioHardwareDestroyAggregateDevice(agg) }
        guard let channels = try? HAL.bufferChannelCounts(agg, scope: kAudioObjectPropertyScopeInput).reduce(0, +),
              (1...CaptureFormatPolicy.maxChannels).contains(channels) else { return (.unavailable, "tapChannels") }
        let ring = RealtimeRing(channels: channels)
        guard let proc = try? RingAudioSource.startIOProc(device: agg, ring: ring) else { return (.unavailable, "ioproc") }
        defer { RingAudioSource.stopIOProc(device: agg, procID: proc) }

        // 3. Look for signal.
        let deadline = ContinuousClock.now + timeout
        var chunk = amr_chunk()
        var scratch = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES) * channels)
        var framesSeen = 0
        while ContinuousClock.now < deadline {
            while scratch.withUnsafeMutableBufferPointer({ amr_ring_pop(ring.raw, &chunk, $0.baseAddress) }) {
                let n = Int(chunk.frame_count) * channels
                framesSeen += Int(chunk.frame_count)
                if scratch[0..<n].contains(where: { abs($0) > 1e-3 }) { return (.granted, "signal after \(framesSeen) frames") }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return framesSeen > 0 ? (.denied, "\(framesSeen) frames, all silent") : (.unavailable, "no tap callbacks")
    }
}
