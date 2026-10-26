public import Foundation
public import Domain
public import Storage

/// The private scratchpad typed while recording (T33): saved as a scratchpad revision of the meeting, which the
/// Notes tab shows as "Private scratchpad" after Stop. Keeps the meeting's "use in notes" choice.
public enum RecordingScratchpad {
    /// Saves `text` unless it equals the latest revision. Returns true when a revision was written.
    @discardableResult
    public static func save(_ text: String, for id: MeetingID, in store: MeetingStore, at date: Date = Date()) throws -> Bool {
        let latest = try store.latestScratchpad(id)
        guard latest?.text != text else { return false }
        try store.saveScratchpad(ScratchpadRevision(meetingID: id, text: text, includeInSummary: latest?.includeInSummary ?? false, createdAt: date))
        return true
    }
}
