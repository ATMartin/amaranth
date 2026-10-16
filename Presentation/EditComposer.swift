public import Foundation
public import Domain

/// Builds user edits against the meeting's current machine revision. Edits are stored separately and replayed by the
/// reconciler after reprocessing; names are only ever what the user typed.
public struct EditComposer: Sendable {
    public let meetingID: MeetingID
    public let revision: TranscriptRevision
    public let existing: [UserEdit]

    public init(meetingID: MeetingID, revision: TranscriptRevision, existing: [UserEdit]) {
        self.meetingID = meetingID; self.revision = revision; self.existing = existing
    }

    var nextSequence: Int { (existing.map(\.sequence).max() ?? 0) + 1 }

    func edit(_ op: EditOperation) -> UserEdit {
        UserEdit(meetingID: meetingID, baseRevisionID: revision.id, sequence: nextSequence, createdAt: Date(), operation: op)
    }

    public enum Error: Swift.Error, Equatable { case emptyName, sameSpeaker, nothingSelected }

    /// Rename (or clear the name with nil/empty, returning to the automatic label).
    public func rename(_ speaker: SpeakerID, to name: String?) -> UserEdit {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return edit(.renameSpeaker(speaker, displayName: (trimmed?.isEmpty ?? true) ? nil : trimmed))
    }

    public func merge(_ sources: [SpeakerID], into target: SpeakerID) throws -> UserEdit {
        let s = sources.filter { $0 != target }
        guard !s.isEmpty else { throw Error.sameSpeaker }
        return edit(.mergeSpeakers(sources: s, into: target))
    }

    /// Assign a row's words to an existing speaker, a new speaker, or "unknown".
    public func reassign(_ row: TranscriptRow, to target: SpeakerTarget) throws -> UserEdit {
        guard let r = row.range else { throw Error.nothingSelected }
        return edit(.reassign(r, to: target))
    }

    /// A new speaker gets a client-side ID and the next free automatic label, so the edit is replayable.
    public func newSpeakerTarget() -> SpeakerTarget {
        let used = Set(revision.speakers.map(\.label))
        var n = revision.speakers.count + 1
        while used.contains("Speaker \(n)") { n += 1 }
        return .new(SpeakerID("user-\(UUID().uuidString.prefix(8))"), label: "Speaker \(n)")
    }

    public func correct(_ row: TranscriptRow, text: String) throws -> UserEdit {
        guard let r = row.range else { throw Error.nothingSelected }
        return edit(.correctText(r, replacement: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public func markUncertain(_ row: TranscriptRow) throws -> UserEdit {
        guard let r = row.range else { throw Error.nothingSelected }
        return edit(.markUncertain(r))
    }
}
