public import AVFoundation
import CoreAudio
import Foundation
import Domain

/// Device-selectable microphone capture via a HAL IOProc directly on the chosen input device.
/// Never changes the user's system default input. A pinned device that disappears is reported; falling back to the
/// default input happens only when the user enabled that preference.
public final class HALInputSource: RingAudioSource, @unchecked Sendable {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [HALListener] = []
    private var config: AudioSourceConfiguration?
    private var waitingForDevice = false
    private var retryTimer: (any DispatchSourceTimer)?

    public init() { super.init(kind: .microphone) }

    public static func authorizationStatus() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Requests microphone access through the normal system prompt.
    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    override func open(_ config: AudioSourceConfiguration) throws {
        self.config = config
        switch Self.authorizationStatus() {
        case .denied, .restricted:
            continuation.yield(.permissionDenied)
            throw AudioSourceError.permissionDenied(.microphone)
        default: break
        }
        let dev = try resolveDevice(config)
        try openDevice(dev)
        installSystemListeners()
    }

    private func resolveDevice(_ config: AudioSourceConfiguration) throws -> AudioObjectID {
        if let uid = config.deviceUID {
            if let d = try HAL.device(forUID: uid), HAL.isAlive(d) { return d }
            guard config.allowDefaultDeviceFallback else { throw AudioSourceError.deviceUnavailable(uid) }
        }
        let d = try HAL.defaultDevice(input: true)
        guard d != kAudioObjectUnknown else { throw AudioSourceError.deviceUnavailable("default input") }
        return d
    }

    private func openDevice(_ dev: AudioObjectID) throws {
        let asbd = try HAL.inputVirtualFormat(dev)
        let counts = try HAL.bufferChannelCounts(dev, scope: kAudioObjectPropertyScopeInput)
        var format = try CaptureFormatPolicy.format(from: asbd)
        format.channelCount = counts.reduce(0, +)
        try CaptureFormatPolicy.validate(format)
        let ring = RealtimeRing(channels: format.channelCount)
        ring.setBufferSelection(first: 0, count: counts.count)
        let name = HAL.deviceName(dev)
        setRing(ring, format: format, deviceName: name)
        procID = try Self.startIOProc(device: dev, ring: ring)
        device = dev
        waitingForDevice = false
        listeners = [
            try HALListener(dev, HAL.address(kAudioDevicePropertyDeviceIsAlive), queue: control) { [weak self] in
                self?.handleDeviceLost(reason: "device.notAlive")
            },
            try HALListener(dev, HAL.address(kAudioDevicePropertyNominalSampleRate), queue: control) { [weak self] in
                self?.handleRebuild(reason: "device.sampleRateChanged")
            },
            try HALListener(dev, HAL.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
                            queue: control) { [weak self] in self?.handleRebuild(reason: "device.streamConfigChanged") },
        ]
        continuation.yield(.started(format: format, deviceUID: HAL.deviceUID(dev), deviceName: name, hostTimeNanos: HostClock.nowNanos()))
    }

    private var systemListeners: [HALListener] = []
    private func installSystemListeners() {
        guard systemListeners.isEmpty else { return }
        systemListeners = [
            (try? HALListener(AudioObjectID(kAudioObjectSystemObject), HAL.address(kAudioHardwarePropertyDevices), queue: control) {
                [weak self] in self?.handleDeviceListChanged()
            }),
            (try? HALListener(AudioObjectID(kAudioObjectSystemObject), HAL.address(kAudioHardwarePropertyDefaultInputDevice), queue: control) {
                [weak self] in self?.handleDefaultInputChanged()
            }),
        ].compactMap { $0 }
    }

    override func close() {
        retryTimer?.cancel()
        retryTimer = nil
        listeners = []
        systemListeners = []
        closeDevice()
        waitingForDevice = false
    }

    private func closeDevice() {
        if let procID, device != kAudioObjectUnknown { Self.stopIOProc(device: device, procID: procID) }
        procID = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Device changes (all on `control`)

    private func handleDeviceLost(reason: String) {
        guard procID != nil, !HAL.isAlive(device) else { return }
        listeners = []
        closeDevice()
        setStatus(.degraded)
        waitingForDevice = true
        continuation.yield(.deviceLost(reasonCode: reason))
        tryReopen()
        scheduleRetry()
    }

    private func handleRebuild(reason: String) {
        guard procID != nil else { return }
        let old = format
        listeners = []
        closeDevice()
        continuation.yield(.deviceLost(reasonCode: reason))
        waitingForDevice = true
        tryReopen()
        if let f = format, f != old, !waitingForDevice { continuation.yield(.formatChanged(f)) }
        if waitingForDevice { scheduleRetry() }
    }

    private func handleDeviceListChanged() {
        if waitingForDevice { tryReopen() } else if procID != nil, !HAL.isAlive(device) { handleDeviceLost(reason: "device.removed") }
    }

    private func handleDefaultInputChanged() {
        // Only matters when following the default (no pinned device) or while waiting with fallback enabled.
        guard let config, config.deviceUID == nil || (waitingForDevice && config.allowDefaultDeviceFallback) else { return }
        if procID != nil { handleRebuild(reason: "input.defaultChanged") } else if waitingForDevice { tryReopen() }
    }

    private func tryReopen() {
        guard let config else { return }
        do {
            let dev = try resolveDevice(config)
            try openDevice(dev)
            setStatus(.healthy)
            retryTimer?.cancel()
            retryTimer = nil
            continuation.yield(.deviceRecovered(deviceUID: HAL.deviceUID(dev), deviceName: HAL.deviceName(dev)))
        } catch {
            setStatus(.degraded)
        }
    }

    /// Polls once per second while waiting so recovery happens within the 5 s budget even without a HAL notification.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.waitingForDevice else { self?.retryTimer?.cancel(); self?.retryTimer = nil; return }
            self.tryReopen()
        }
        t.resume()
        retryTimer = t
    }
}
