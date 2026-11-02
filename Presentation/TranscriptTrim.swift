public import Domain

/// Wording for T96's “Start from Here…” / “End Here…” confirmations.
public enum TranscriptTrim {
    public enum Kind: Sendable, Hashable { case start, end }

    public static func title(_ kind: Kind, at t: SessionTime) -> String {
        switch kind {
        case .start: "Start the meeting at \(TranscriptRows.clock(t))?"
        case .end: "End the meeting after this line?"
        }
    }

    public static func confirmLabel(_ kind: Kind) -> String {
        switch kind {
        case .start: "Delete Everything Before"
        case .end: "Delete Everything After"
        }
    }

    public static func message(_ kind: Kind, at row: TranscriptRow, audioPresent: Bool) -> String {
        let what = switch kind {
        case .start: audioPresent ? "the transcript and audio before \(TranscriptRows.clock(row.start))" : "the transcript before \(TranscriptRows.clock(row.start))"
        case .end: audioPresent ? "the transcript and audio after \(TranscriptRows.clock(row.end))" : "the transcript after \(TranscriptRows.clock(row.end))"
        }
        return "Deletes \(what). This cannot be undone. Notes stay as they are; regenerate them if you need to."
    }
}
