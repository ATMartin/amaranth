import CaptureRT
import CoreAudio
import Foundation
public import Domain

/// Shared plumbing for HAL-IOProc-backed sources: event stream, status, and the C ring the IOProc fills.
/// Subclasses implement `open(configuration)` / `close()`.
public class RingAudioSource: AudioSource, @unchecked Sendable {
    public let kind: SourceKind
    public let events: AsyncStream<AudioSourceEvent>
    let continuation: AsyncStream<AudioSourceEvent>.Continuation
    /// Serializes start/stop/rebuild and HAL listener callbacks.
    let control: DispatchQueue

    private let lock = NSLock()
    private var _status: SourceHealth.Status = .inactive
    private var _ring: RealtimeRing?
    private var _format: AudioFormat?
    private var _deviceName: String?

    init(kind: SourceKind) {
        self.kind = kind
        control = DispatchQueue(label: "amaranth.capture.\(kind.rawValue).control")
        (events, continuation) = AsyncStream.makeStream(of: AudioSourceEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Current ring; replaced on format/device rebuilds. The writer drains whatever ring is current.
    public var ring: RealtimeRing? { lock.withLock { _ring } }
    public var format: AudioFormat? { lock.withLock { _format } }

    func setRing(_ r: RealtimeRing?, format: AudioFormat?, deviceName: String?) {
        lock.withLock { _ring = r; _format = format; _deviceName = deviceName }
    }

    func setStatus(_ s: SourceHealth.Status) { lock.withLock { _status = s } }

    public func health() -> SourceHealth {
        let (status, ring, name) = lock.withLock { (_status, _ring, _deviceName) }
        let stats = ring?.stats()
        return SourceHealth(source: kind, status: status,
                            lastCallbackHostNanos: stats.map { HostClock.ticksToNanos($0.lastCallbackHostTicks) },
                            overrunCount: Int(stats?.overrunEvents ?? 0), deviceName: name)
    }

    public func start(_ configuration: AudioSourceConfiguration) throws {
        try control.sync {
            setStatus(.starting)
            do {
                try open(configuration)
                setStatus(.healthy)
            } catch {
                setStatus(error as? AudioSourceError == .permissionDenied(kind) ? .permissionDenied : .failed)
                throw error
            }
        }
    }

    public func stop() {
        control.sync {
            close()
            setStatus(.inactive)
            continuation.yield(.stopped)
        }
    }

    // MARK: Subclass hooks (called on `control`)
    func open(_ configuration: AudioSourceConfiguration) throws { fatalError("abstract") }
    func close() { fatalError("abstract") }

    /// Creates and starts an IOProc on `device` that feeds `ring` through the C callback.
    static func startIOProc(device: AudioObjectID, ring: RealtimeRing) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        // The IOProc is the C function amr_ioproc: no Swift code runs on the realtime thread.
        try HAL.check(amr_create_ioproc(device, ring.raw, &procID), "create IOProc")
        guard let procID else { throw HAL.Error(status: kAudioHardwareUnspecifiedError, what: "create IOProc") }
        do {
            try HAL.check(AudioDeviceStart(device, procID), "start device")
        } catch {
            AudioDeviceDestroyIOProcID(device, procID)
            throw error
        }
        return procID
    }

    static func stopIOProc(device: AudioObjectID, procID: AudioDeviceIOProcID) {
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
    }
}
