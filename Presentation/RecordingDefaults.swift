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

    /// The folder new recordings are filed in (T42); unset = none. Stored as the folder's ID, so a rename keeps it.
    public static let folderKey = "defaultFolderID"
    public static func folder(_ d: UserDefaults = .standard) -> FolderID? { d.string(forKey: folderKey).map(FolderID.init) }

    /// The folder a recording starts in: the chosen one while it exists, else none (a deleted folder never blocks Record).
    public static func resolveFolder(_ id: FolderID?, folders: [Folder]) -> FolderID? {
        guard let id, folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public static let missingMicrophoneNotice = "Your chosen microphone isn't connected, so this meeting records from the system default microphone."

    /// The microphone to record with: the chosen one if connected, otherwise System default plus a notice.
    /// No microphone is used for system-audio-only recordings, so there is nothing to fall back from.
    public static func resolveMicrophone(_ uid: String?, sources: SourceSelection, connected: [String]) -> (uid: String?, notice: String?) {
        guard let uid, sources != .systemOnly else { return (uid, nil) }
        return connected.contains(uid) ? (uid, nil) : (nil, missingMicrophoneNotice)
    }
}
