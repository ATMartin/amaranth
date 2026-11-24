import Foundation
public import Domain

/// Deterministic generated source for writer/timeline tests and the headless replay harness.
/// Pushes frames from a timer thread through the same C ring path as the hardware sources.
public final class SyntheticSource: RingAudioSource, @unchecked Sendable {
    public struct Plan: Sendable {
        public var format: AudioFormat
        public var callbackFrames: Int
        /// Sample generator: (frameIndexInStream, channel) → sample.
        public var signal: @Sendable (Int64, Int) -> Float
        /// Device sample-time jumps to inject: at stream frame → skip this many frames (simulates a device glitch).
        public var sampleTimeJumps: [Int64: Int64]
        /// Run faster than realtime (for tests). 1 = realtime.
        public var speed: Double
        /// Host clock rate error relative to the sample clock, in parts per million (simulates crystal drift).
        public var hostClockPPM: Double = 0

        public init(format: AudioFormat, callbackFrames: Int = 480, speed: Double = 1, sampleTimeJumps: [Int64: Int64] = [:],
                    signal: @escaping @Sendable (Int64, Int) -> Float) {
            self.format = format
            self.callbackFrames = callbackFrames
            self.speed = speed
            self.sampleTimeJumps = sampleTimeJumps
            self.signal = signal
        }

        public static func sine(_ hz: Double, amplitude: Float = 0.25, format: AudioFormat, speed: Double = 1) -> Plan {
            Plan(format: format, speed: speed) { i, _ in amplitude * Float(sin(2 * .pi * hz * Double(i) / Double(format.sampleRate))) }
        }
    }

    public private(set) var plan: Plan
    private var configuration: AudioSourceConfiguration?
    private var thread: Thread?
    private let stopFlag = NSLock()
    private var stopping = false
    /// When true, the generator stops calling back (simulates a stalled device) without stopping the source.
    public var stalled: Bool {
        get { stopFlag.withLock { _stalled } }
        set { stopFlag.withLock { _stalled = newValue } }
    }
    private var _stalled = false

    public init(kind: SourceKind, plan: Plan) {
        self.plan = plan
        super.init(kind: kind)
    }

    /// Test hook: rebuilds the stream at a new format, like a device sample-rate change (new ring → new epoch).
    /// The generator restarts at stream frame 0 at the new rate.
    public func rebuild(format: AudioFormat) throws {
        try control.sync {
            close()
            plan.format = format
            guard let configuration else { return }
            try open(configuration)
            continuation.yield(.formatChanged(format))
        }
    }

    override func open(_ configuration: AudioSourceConfiguration) throws {
        self.configuration = configuration
        try CaptureFormatPolicy.validate(plan.format)
        let ring = RealtimeRing(channels: plan.format.channelCount)
        setRing(ring, format: plan.format, deviceName: "Synthetic \(kind.rawValue)")
        stopFlag.withLock { stopping = false }
        let plan = self.plan
        let t = Thread { [weak self] in
            var frame: Int64 = 0
            var sampleTime: Double = 0
            let ch = plan.format.channelCount
            var buf = [Float](repeating: 0, count: plan.callbackFrames * ch)
            let period = Double(plan.callbackFrames) / Double(plan.format.sampleRate) / plan.speed
            // Host clock model: frames advance host time (scaled by speed); a stall rebases it like a real device
            // whose callbacks stopped while wall time moved on.
            var baseHost = HostClock.nowNanos()
            var baseFrame: Int64 = 0
            var paceBase = baseHost
            var n = 0
            var wasStalled = false
            while let self, !self.stopFlag.withLock({ self.stopping }) {
                if self.stalled { wasStalled = true; Thread.sleep(forTimeInterval: 0.01); continue }
                if wasStalled {
                    wasStalled = false
                    let virtualNow = baseHost + UInt64(Double(frame - baseFrame) / Double(plan.format.sampleRate) * 1e9)
                    baseHost = max(HostClock.nowNanos(), virtualNow); baseFrame = frame; n = 0
                    paceBase = HostClock.nowNanos()
                }
                if let skip = plan.sampleTimeJumps[frame] { sampleTime += Double(skip); frame += skip }
                for i in 0..<plan.callbackFrames { for c in 0..<ch { buf[i * ch + c] = plan.signal(frame + Int64(i), c) } }
                // Virtual host time advances with sample time (consistent clocks); only pacing is scaled by `speed`.
                let hostNs = baseHost + UInt64(Double(frame - baseFrame) / Double(plan.format.sampleRate) * 1e9 * (1 + plan.hostClockPPM / 1e6))
                ring.pushInterleaved(buf, hostTime: Self.nanosToTicks(hostNs), sampleTime: sampleTime)
                frame += Int64(plan.callbackFrames)
                sampleTime += Double(plan.callbackFrames)
                n += 1
                let target = Double(n) * period
                let elapsed = Double(HostClock.nowNanos() - paceBase) / 1e9
                if target > elapsed { Thread.sleep(forTimeInterval: target - elapsed) }
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        continuation.yield(.started(format: plan.format, deviceUID: "synthetic", deviceName: "Synthetic", hostTimeNanos: HostClock.nowNanos()))
    }

    override func close() {
        stopFlag.withLock { stopping = true }
        while thread?.isFinished == false { Thread.sleep(forTimeInterval: 0.001) }
        thread = nil
    }

    static func nanosToTicks(_ ns: UInt64) -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return UInt64((Double(ns) * Double(tb.denom) / Double(tb.numer)).rounded())
    }
}
