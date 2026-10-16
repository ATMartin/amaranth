public import CoreAudio
import Foundation
import Domain

/// Minimal typed access to Core Audio HAL properties. Never used on the realtime thread.
enum HAL {
    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        let what: String
        var description: String { "\(what) failed: OSStatus \(status) (\(fourCC(status)))" }
        var asSourceError: AudioSourceError { .osStatus(status, what) }
    }

    static func fourCC(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let bytes = [24, 16, 8, 0].map { UInt8((u >> $0) & 0xff) }
        return bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) ? String(decoding: bytes, as: UTF8.self) : "\(s)"
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        if status != noErr { throw Error(status: status, what: what()) }
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) throws -> T {
        var addr = addr
        var v = value
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &v), "get \(fourCC(OSStatus(bitPattern: addr.mSelector)))")
        return v
    }

    static func getArray<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type, zero: T) throws -> [T] {
        var addr = addr
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size")
        let count = Int(size) / MemoryLayout<T>.stride
        var arr = [T](repeating: zero, count: count)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &arr), "array")
        return Array(arr.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func hasProperty(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        return AudioObjectHasProperty(object, &addr)
    }

    // MARK: Devices

    static func allDevices() throws -> [AudioObjectID] {
        try getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)
    }

    static func defaultDevice(input: Bool) throws -> AudioObjectID {
        try get(AudioObjectID(kAudioObjectSystemObject),
                address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice),
                default: AudioObjectID(0))
    }

    static func deviceUID(_ d: AudioObjectID) -> String? { getString(d, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ d: AudioObjectID) -> String? { getString(d, kAudioObjectPropertyName) }

    static func device(forUID uid: String) throws -> AudioObjectID? {
        try allDevices().first { deviceUID($0) == uid }
    }

    static func isAlive(_ d: AudioObjectID) -> Bool {
        ((try? get(d, address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0) != 0
    }

    static func nominalSampleRate(_ d: AudioObjectID) throws -> Double {
        try get(d, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
    }

    static func transportType(_ d: AudioObjectID) -> UInt32 {
        (try? get(d, address(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
    }

    /// Per-buffer channel counts of the device's stream configuration in `scope`.
    static func bufferChannelCounts(_ d: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size), "stream config size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(d, &addr, 0, nil, &size, raw), "stream config")
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }
    }

    /// Virtual (IOProc-facing) format of the first input stream.
    static func inputVirtualFormat(_ d: AudioObjectID) throws -> AudioStreamBasicDescription {
        let streams = try getArray(d, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), of: AudioObjectID.self, zero: 0)
        guard let s = streams.first else { throw Error(status: kAudioHardwareBadStreamError, what: "no input stream") }
        return try get(s, address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
    }

    static func inputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().compactMap { d in
            let counts = (try? bufferChannelCounts(d, scope: kAudioObjectPropertyScopeInput)) ?? []
            let ch = counts.reduce(0, +)
            guard ch > 0, let uid = deviceUID(d) else { return nil }
            // Hide our own private aggregate/tap devices.
            if uid.hasPrefix(SystemAudioTapSource.aggregateUIDPrefix) { return nil }
            return AudioDeviceInfo(id: d, uid: uid, name: deviceName(d) ?? uid, inputChannels: ch,
                                   sampleRate: (try? nominalSampleRate(d)) ?? 0, transport: transportType(d))
        }
    }

    static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj), "translate pid")
        return obj
    }
}

public struct AudioDeviceInfo: Hashable, Sendable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let sampleRate: Double
    public let transport: UInt32

    public var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        default: HAL.fourCC(OSStatus(bitPattern: transport))
        }
    }
}

public enum AudioDevices {
    public static func inputs() -> [AudioDeviceInfo] { (try? HAL.inputDevices()) ?? [] }
    public static func defaultInputUID() -> String? { (try? HAL.defaultDevice(input: true)).flatMap(HAL.deviceUID) }
    public static func defaultOutputUID() -> String? { (try? HAL.defaultDevice(input: false)).flatMap(HAL.deviceUID) }

    public static func outputs() -> [AudioDeviceInfo] {
        ((try? HAL.allDevices()) ?? []).compactMap { d in
            let ch = ((try? HAL.bufferChannelCounts(d, scope: kAudioObjectPropertyScopeOutput)) ?? []).reduce(0, +)
            guard ch > 0, let uid = HAL.deviceUID(d), !uid.hasPrefix(SystemAudioTapSource.aggregateUIDPrefix) else { return nil }
            return AudioDeviceInfo(id: d, uid: uid, name: HAL.deviceName(d) ?? uid, inputChannels: 0,
                                   sampleRate: (try? HAL.nominalSampleRate(d)) ?? 0, transport: HAL.transportType(d))
        }
    }

    /// Changes the system default device. Used only by route-change qualification tests, which restore the original.
    @discardableResult
    public static func setDefault(input: Bool, uid: String) -> Bool {
        guard let dev = try? HAL.device(forUID: uid) else { return false }
        var addr = HAL.address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var d = dev
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
    }
}

/// RAII wrapper for a property listener block; removes itself on deinit.
final class HALListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, queue: DispatchQueue,
         _ handler: @escaping @Sendable () -> Void) throws {
        self.object = object
        self.addr = addr
        self.queue = queue
        self.block = { _, _ in handler() }
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &self.addr, queue, block), "add listener")
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block) }
}
