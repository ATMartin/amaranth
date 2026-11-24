import CoreAudio
import Foundation

/// Which other apps are using audio input right now (T68, T122: "the call app let go of the microphone"), from Core
/// Audio's process objects. Amaranth and its helpers (bundle ids starting with `excludingBundlePrefix`, and this process)
/// are left out. Only an identifier per process is returned (its bundle id, or "pid:N" without one), and the caller
/// keeps it only for the recording. Not for the realtime thread: a couple of times a second is plenty.
public enum MicrophoneUse {
    /// nil when Core Audio can't say (the property is missing or fails), so the caller can ignore the signal.
    public static func inputUsers(excludingBundlePrefix prefix: String = "com.alexmartin.amaranth") -> Set<String>? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let processes = try? HAL.getArray(system, HAL.address(kAudioHardwarePropertyProcessObjectList),
                                                of: AudioObjectID.self, zero: 0) else { return nil }
        let me = getpid()
        var users: Set<String> = []
        for p in processes {
            guard (try? HAL.get(p, HAL.address(kAudioProcessPropertyIsRunningInput), default: UInt32(0))) == 1 else { continue }
            let pid = (try? HAL.get(p, HAL.address(kAudioProcessPropertyPID), default: pid_t(0))) ?? 0
            if pid == me { continue }
            if let id = HAL.getString(p, kAudioProcessPropertyBundleID), !id.isEmpty {
                if id.hasPrefix(prefix) { continue }
                users.insert(id)
            } else {
                users.insert("pid:\(pid)")
            }
        }
        return users
    }
}
