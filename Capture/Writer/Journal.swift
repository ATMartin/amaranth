public import Domain

/// Append-only capture journal (`journal.jsonl`, one `Versioned<JournalEntry>` JSON object per line).
/// Segment lines are written only after the segment file is durable in its final location; epoch lines are synced
/// immediately. With self-describing segment files, the journal lets recovery rebuild the index without the database.
public enum JournalEntry: Codable, Sendable, Hashable {
    case segment(AudioSegmentRecord)
    case epoch(CaptureEpoch)
    case event(CaptureEvent)
}
