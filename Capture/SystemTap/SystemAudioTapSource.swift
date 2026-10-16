import CoreAudio
import Foundation
import Domain

/// System-output capture through a private, non-muting Core Audio process tap on a private aggregate device
/// (plan §5 "System capture decision"). Captures every process's output — including processes launched after
/// recording starts — except Amaranth itself. No virtual driver, no output-device replacement, no private TCC API.
public final class SystemAudioTapSource: RingAudioSource, @unchecked Sendable {
    static let aggregateUIDPrefix = "com.alexmartin.amaranth.tap."

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [HALListener] = []
    private var config: AudioSourceConfiguration?
    /// Diagnostics for the compatibility matrix.
    public private(set) var diagnostics: [String: String] = [:]

    public init() { super.init(kind: .systemOutput) }

    override func open(_ config: AudioSourceConfiguration) throws {
        self.config = config
        var excluded: [AudioObjectID] = []
        let selfObject = (try? HAL.translatePIDToProcessObject(getpid())) ?? AudioObjectID(kAudioObjectUnknown)
        if selfObject != kAudioObjectUnknown { excluded.append(selfObject) }
        for pid in config.excludedProcessIDs {
            if let o = try? HAL.translatePIDToProcessObject(pid), o != kAudioObjectUnknown { excluded.append(o) }
        }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "Amaranth system capture"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        // Exclude our own bundle even if our process object did not exist yet (macOS 26+; our floor is 26.5.2).
        desc.bundleIDs = [WorkerIdentity.appBundleID]
        diagnostics["selfProcessObject"] = selfObject == kAudioObjectUnknown ? "unavailable" : "\(selfObject)"
        diagnostics["excludedBundleIDs"] = WorkerIdentity.appBundleID

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw AudioSourceError.osStatus(status, "AudioHardwareCreateProcessTap")
        }
        tapID = tap

        do {
            let asbd = try HAL.get(tap, HAL.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
            let format: AudioFormat
            do { format = try CaptureFormatPolicy.format(from: asbd) } catch {
                diagnostics["unsupportedFormat"] = "\(asbd.mSampleRate)Hz/\(asbd.mChannelsPerFrame)ch/flags=\(asbd.mFormatFlags)"
                throw error
            }

            let aggUID = Self.aggregateUIDPrefix + UUID().uuidString
            let dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Amaranth Capture",
                kAudioAggregateDeviceUIDKey: aggUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            try HAL.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "create aggregate device")
            aggregateID = agg

            // The tap-only aggregate exposes the tap as its input stream(s). Select exactly those buffers.
            let counts = try HAL.bufferChannelCounts(agg, scope: kAudioObjectPropertyScopeInput)
            diagnostics["aggregateInputBuffers"] = counts.map(String.init).joined(separator: ",")
            guard counts.reduce(0, +) == format.channelCount else {
                throw AudioSourceError.unsupportedFormat(format)
            }
            let ring = RealtimeRing(channels: format.channelCount)
            ring.setBufferSelection(first: 0, count: counts.count)
            setRing(ring, format: format, deviceName: "System output")
            procID = try Self.startIOProc(device: agg, ring: ring)
            diagnostics["format"] = format.description

            // The global tap is device-independent: switching the default output (verified with a virtual device,
            // capture-routes) needs no rebuild, and rebuilding would only add a gap. Rebuild only if the tap's format changes.
            listeners = [
                try HALListener(tap, HAL.address(kAudioTapPropertyFormat), queue: control) { [weak self] in
                    self?.handleRouteChange(reason: "tap.formatChanged")
                },
            ]
            continuation.yield(.started(format: format, deviceUID: "amaranth.systemTap", deviceName: "System output",
                                        hostTimeNanos: HostClock.nowNanos()))
        } catch {
            close()
            throw error
        }
    }

    override func close() {
        listeners = []
        if let procID, aggregateID != kAudioObjectUnknown { Self.stopIOProc(device: aggregateID, procID: procID) }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Ring is kept until the writer drains it; the next open installs a fresh one.
    }

    /// Runs on `control`. Tears down and rebuilds the tap; the writer sees a new ring and starts a new epoch.
    private func handleRouteChange(reason: String) {
        guard procID != nil else { return }
        let oldFormat = format
        continuation.yield(.deviceLost(reasonCode: reason))
        setStatus(.degraded)
        close()
        do {
            guard let config else { throw AudioSourceError.deviceUnavailable("system tap: no configuration") }
            try open(config)
            setStatus(.healthy)
            if let f = format, f != oldFormat { continuation.yield(.formatChanged(f)) }
            continuation.yield(.deviceRecovered(deviceUID: "amaranth.systemTap", deviceName: "System output"))
        } catch {
            setStatus(.failed)
        }
    }
}
