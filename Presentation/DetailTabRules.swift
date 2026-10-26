public import Domain

/// Which tab a meeting opens on (T32): the transcript while it is being recorded or transcribed, Notes once notes exist.
public enum DetailTabRules {
    public enum Tab: Sendable, Equatable { case notes, transcript }

    /// Recording, or a provisional/pending transcript → Transcript; notes exist → Notes; otherwise (final transcript
    /// without notes yet, or no notes model) → Transcript.
    public static func defaultTab(isRecording: Bool, hasFinalTranscript: Bool, hasSummary: Bool) -> Tab {
        if isRecording || !hasFinalTranscript { return .transcript }
        return hasSummary ? .notes : .transcript
    }
}

extension MeetingDetail {
    public func defaultTab(isRecording: Bool) -> DetailTabRules.Tab {
        DetailTabRules.defaultTab(isRecording: isRecording, hasFinalTranscript: transcript != nil && !showingProvisional,
                                  hasSummary: summary != nil)
    }
}

/// After Stop the meeting stays on Transcript; when its first notes arrive while the user is still viewing it, show
/// Notes once. Any tab choice by the user for that meeting cancels the switch: never fight the user. Session-only.
public struct NotesArrivalSwitch: Sendable {
    private var waiting: Set<MeetingID> = []

    public init() {}

    /// A recording just stopped. Without a notes model no notes will come, so never switch.
    public mutating func stopped(_ id: MeetingID, notesModelReady: Bool) {
        if notesModelReady { waiting.insert(id) } else { waiting.remove(id) }
    }

    public mutating func userChoseTab(_ id: MeetingID) { waiting.remove(id) }

    public func isWaiting(_ id: MeetingID) -> Bool { waiting.contains(id) }

    /// Call whenever the viewed meeting's detail refreshes. True exactly once: when its notes first exist.
    public mutating func shouldSwitchToNotes(viewing id: MeetingID, hasSummary: Bool) -> Bool {
        guard hasSummary, waiting.contains(id) else { return false }
        waiting.remove(id)
        return true
    }
}
