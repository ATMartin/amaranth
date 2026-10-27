import CoreAudio
import Foundation

/// Whether any other app is using audio input right now (T68's "the call app let go of the microphone"), from Core
/// Audio's process objects. Amaranth and its helpers (bundle ids starting with `excludingBundlePrefix`, and this process)
/// are left out. Nothing about the other processes is kept. Not for the realtime thread: about 1 Hz is plenty.
public enum MicrophoneUse {
    /// nil when Core Audio can't say (the property is missing or fails), so the caller can ignore the signal.
    public static func othersUsingInput(excludingBundlePrefix prefix: String = "com.alexmartin.amaranth") -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let processes = try? HAL.getArray(system, HAL.address(kAudioHardwarePropertyProcessObjectList),
                                                of: AudioObjectID.self, zero: 0) else { return nil }
        let me = getpid()
        for p in processes {
            guard (try? HAL.get(p, HAL.address(kAudioProcessPropertyIsRunningInput), default: UInt32(0))) == 1 else { continue }
            if (try? HAL.get(p, HAL.address(kAudioProcessPropertyPID), default: pid_t(0))) == me { continue }
            if let id = HAL.getString(p, kAudioProcessPropertyBundleID), id.hasPrefix(prefix) { continue }
            return true
        }
        return false
    }
}
