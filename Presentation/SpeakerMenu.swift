public import Domain

/// What the speaker menus offer (T38): the SpeakerBar (one speaker) and the transcript's speaker column (the row's
/// speakers). Both turn a choice into the same `EditComposer` call, so the resulting `UserEdit`s are identical.
public enum SpeakerMenu {
    /// Speakers the row's speaker menu can rename or merge: the row's speakers in speaker-list order; none for unknown.
    public static func subjects(of row: TranscriptRow, in speakers: [Speaker]) -> [Speaker] {
        let ids = Set(row.assignment.speakerIDs)
        return speakers.filter { ids.contains($0.id) }
    }

    /// "Merge Into" targets for a speaker: every other speaker, in list order.
    public static func mergeTargets(for speaker: Speaker, in speakers: [Speaker]) -> [Speaker] {
        speakers.filter { $0.id != speaker.id }
    }

    /// Existing speakers offered by "Assign This Line To", without the row's single current speaker (a no-op).
    public static func assignTargets(for row: TranscriptRow, in speakers: [Speaker]) -> [Speaker] {
        if case .speaker(let id) = row.assignment { speakers.filter { $0.id != id } } else { speakers }
    }
}
