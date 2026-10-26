public import Foundation
public import Domain

/// Recording defaults (T30): what a single Record click uses. Set in Settings → Recording; a per-meeting choice in the
/// Record menu (T31) applies to that recording only and never overwrites these.
public enum RecordingDefaults {
    /// UserDefaults keys, kept from before T30 so existing users keep their choice. A test pins them.
    public static let sourcesKey = "defaultSources"
    public static let microphoneKey = "microphoneUID"
    public static let sourcesDefault = SourceSelection.both

    public static func sources(_ d: UserDefaults = .standard) -> SourceSelection {
        SourceSelection(rawValue: d.string(forKey: sourcesKey) ?? "") ?? sourcesDefault
    }

    /// nil = System default.
    public static func microphone(_ d: UserDefaults = .standard) -> String? { d.string(forKey: microphoneKey) }

    public static let missingMicrophoneNotice = "Your chosen microphone isn't connected, so this meeting records from the system default microphone."

    /// The microphone to record with: the chosen one if connected, otherwise System default plus a notice.
    /// No microphone is used for system-audio-only recordings, so there is nothing to fall back from.
    public static func resolveMicrophone(_ uid: String?, sources: SourceSelection, connected: [String]) -> (uid: String?, notice: String?) {
        guard let uid, sources != .systemOnly else { return (uid, nil) }
        return connected.contains(uid) ? (uid, nil) : (nil, missingMicrophoneNotice)
    }
}
