public import Foundation
public import Domain
public import Storage

/// Notes typed while recording (spec 0008 §2): the live view's Notes field. Each line becomes a user block of the
/// meeting's notes document with the recording time it was first typed, so generation can relate it to what was being
/// said then. Lines keep their block (and time) while edited.
public struct RecordingNotes: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var id = NoteBlockID()
        var text: String
        var typedAt: TimeInterval?
    }

    public private(set) var text = ""
    private var lines: [Line] = []
    /// Every block this recording has written, so a save replaces them (a removed line is removed) and leaves the rest.
    private var written: Set<NoteBlockID> = []

    public init() {}

    /// The field's new text at `time` seconds into the recording. Lines are matched to the previous ones by a diff:
    /// unchanged lines keep their block and time; within a run of changes, edited lines pair with the old ones in order.
    public mutating func update(_ text: String, at time: TimeInterval) {
        self.text = text
        let new = text.components(separatedBy: "\n")
        let diff = new.difference(from: lines.map(\.text))
        let removed = Set(diff.removals.map { if case .remove(let o, _, _) = $0 { o } else { -1 } })
        let inserted = Set(diff.insertions.map { if case .insert(let o, _, _) = $0 { o } else { -1 } })
        var oldIndex = 0, pending: [Int] = []   // removed old lines since the last unchanged one
        var result: [Line] = []
        for (i, t) in new.enumerated() {
            let empty = t.trimmingCharacters(in: .whitespaces).isEmpty
            if inserted.contains(i) {
                while oldIndex < lines.count, removed.contains(oldIndex) { pending.append(oldIndex); oldIndex += 1 }
                if !pending.isEmpty {   // an edit of an old line: keep its block and when it was first typed
                    var l = lines[pending.removeFirst()]
                    l.text = t
                    if l.typedAt == nil, !empty { l.typedAt = time }
                    result.append(l)
                } else {
                    result.append(Line(text: t, typedAt: empty ? nil : time))
                }
            } else {
                while oldIndex < lines.count, removed.contains(oldIndex) { oldIndex += 1 }
                pending = []
                result.append(oldIndex < lines.count ? lines[oldIndex] : Line(text: t, typedAt: empty ? nil : time))
                oldIndex += 1
            }
        }
        lines = result
    }

    /// The lines with text as user blocks ("# " a heading, "- " a bullet, as in the Notes tab).
    public var blocks: [NoteBlock] {
        lines.compactMap { l in
            NotesComposer.userBlocks(fromText: l.text, typedAt: l.typedAt).first.map { var b = $0; b.id = l.id; return b }
        }
    }

    /// Writes the lines into the meeting's notes document (a new revision) unless nothing changed. Blocks this recording
    /// did not write are kept in place. Returns true when a revision was saved.
    @discardableResult
    public mutating func save(for id: MeetingID, in store: MeetingStore, at date: Date = Date()) throws -> Bool {
        let live = blocks
        let current = try store.currentNotesDocument(id)
        let kept = (current?.blocks ?? []).filter { !written.contains($0.id) }
        let next = kept + live
        guard next != (current?.blocks ?? []) else { return false }
        let saved = try store.saveNotesDocument(NotesDocumentRevision(meetingID: id, createdAt: date, basedOnSummaryRevisionID: current?.basedOnSummaryRevisionID,
                                                                      origin: .edited, blocks: next))
        if saved { written.formUnion(live.map(\.id)) }
        return saved
    }
}
