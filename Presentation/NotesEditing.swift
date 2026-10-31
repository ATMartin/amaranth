public import Foundation
public import Domain

/// The notes pane's working copy of a meeting's notes document (spec 0008 §6). Edits go through here so the authorship
/// rule holds everywhere: changing a model block's text, detail or sources makes it the user's. A trailing empty line is
/// always there to type into; empty user lines are never saved.
public struct NotesDraft: Equatable, Sendable {
    public var meetingID: MeetingID
    /// The revision this draft started from (nil: the meeting had no notes yet). A save keeps its `basedOnSummaryRevisionID`,
    /// so typing over notes that were regenerated meanwhile shows them as pending instead of overwriting them.
    public private(set) var base: NotesDocumentRevision?
    public private(set) var blocks: [NoteBlock]

    public init(meetingID: MeetingID, base: NotesDocumentRevision?) {
        self.meetingID = meetingID
        self.base = base
        blocks = base?.blocks ?? []
        ensureTrailingLine()
    }

    /// The blocks a save writes: everything but empty user lines.
    public var content: [NoteBlock] { blocks.filter { !($0.isUser && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }

    public var isDirty: Bool { content != (base?.blocks ?? []) }

    public func block(_ id: NoteBlockID) -> NoteBlock? { blocks.first { $0.id == id } }

    /// Sets a block's text. In a user line, "# " makes it a heading and "- " or "* " a bullet (the prefix is removed).
    public mutating func setText(_ id: NoteBlockID, _ text: String) {
        guard let i = blocks.firstIndex(where: { $0.id == id }), blocks[i].text != text else { return }
        var b = blocks[i].editing(text: text)
        if b.isUser, b.kind == .paragraph {
            if text.hasPrefix("# ") { b.kind = .heading; b.text = String(text.dropFirst(2)) }
            else if text.hasPrefix("- ") || text.hasPrefix("* ") { b.kind = .bullet; b.text = String(text.dropFirst(2)) }
        }
        blocks[i] = b
        ensureTrailingLine()
    }

    /// Sets the owner · date line under a next step.
    public mutating func setDetail(_ id: NoteBlockID, _ detail: String) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[i] = blocks[i].editing(detail: .some(detail.isEmpty ? nil : detail))
    }

    /// A new empty user line after `id` (a bullet after a bullet, else a paragraph); at the end when `id` is nil.
    @discardableResult
    public mutating func insertLine(after id: NoteBlockID?) -> NoteBlockID {
        let i = id.flatMap { id in blocks.firstIndex { $0.id == id } }
        // Return on an empty bullet ends the list: the line becomes a paragraph (as in other editors).
        if let i, blocks[i].isUser, blocks[i].kind == .bullet, blocks[i].text.isEmpty {
            blocks[i].kind = .paragraph
            return blocks[i].id
        }
        // Return on the empty trailing line stays on it.
        if let i, i == blocks.count - 1, blocks[i].isUser, blocks[i].text.isEmpty { return blocks[i].id }
        let kind: NoteBlock.Kind = i.map { blocks[$0].kind == .bullet ? .bullet : .paragraph } ?? .paragraph
        let b = NoteBlock(kind: kind, text: "", author: .user(typedAt: nil))
        blocks.insert(b, at: i.map { $0 + 1 } ?? blocks.count)
        ensureTrailingLine()
        return b.id
    }

    /// Removes a line; returns the line before it (where the cursor goes). Generated section headings stay.
    @discardableResult
    public mutating func remove(_ id: NoteBlockID) -> NoteBlockID? {
        guard let i = blocks.firstIndex(where: { $0.id == id }), blocks[i].section == nil else { return nil }
        blocks.remove(at: i)
        ensureTrailingLine()
        return i > 0 ? blocks[i - 1].id : blocks.first?.id
    }

    /// Deleting a source chip removes that evidence (an edit: a model block becomes the user's).
    public mutating func removeEvidence(_ ref: EvidenceRef, from id: NoteBlockID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }), blocks[i].evidence.contains(ref) else { return }
        var b = blocks[i]
        b.evidence.removeAll { $0 == ref }
        if !b.isUser { b.author = .user(typedAt: nil) }
        blocks[i] = b
    }

    /// The revision a save writes.
    public func revision(at date: Date = Date()) -> NotesDocumentRevision {
        NotesDocumentRevision(meetingID: meetingID, createdAt: date, basedOnSummaryRevisionID: base?.basedOnSummaryRevisionID,
                              origin: .edited, blocks: content)
    }

    /// After a save of this draft: the saved revision becomes the base, the typing stays as it is.
    public mutating func didSave(_ saved: NotesDocumentRevision) { base = saved }

    mutating func ensureTrailingLine() {
        if let last = blocks.last, last.isUser, last.kind != .heading, last.text.isEmpty { return }
        blocks.append(NoteBlock(kind: .paragraph, text: "", author: .user(typedAt: nil)))
    }
}

public enum NotesEditing {
    /// The generated section each block sits under (nil before the first heading or for the headings themselves).
    public static func sections(_ blocks: [NoteBlock]) -> [NoteBlockID: NoteSection] {
        var out: [NoteBlockID: NoteSection] = [:], current: NoteSection?
        for b in blocks {
            if let s = b.section { current = s; continue }
            if let current { out[b.id] = current }
        }
        return out
    }

    /// Items under each generated heading (the count beside it), not counting empty lines.
    public static func itemCount(after heading: NoteBlockID, in blocks: [NoteBlock]) -> Int {
        guard let i = blocks.firstIndex(where: { $0.id == heading }) else { return 0 }
        return blocks[(i + 1)...].prefix { $0.section == nil }.filter { $0.kind != .heading && !$0.text.isEmpty }.count
    }

    /// Spec 0008 §5: Regenerate asks first when the notes have the user's edits since they were last generated.
    public static func regenerateNeedsConfirmation(_ current: NotesDocumentRevision?) -> Bool {
        guard let c = current, !c.isEmpty else { return false }
        switch c.origin {
        case .generated: return false
        case .migrated: return !c.userBlocks.isEmpty
        case .edited, .restored: return true
        }
    }

    public static let regenerateQuestion = "Regenerate notes?"
    public static let regenerateExplanation = "Lines you wrote are kept, and you can restore this version from Previous Versions."

    /// Previous Versions: a copy of `old` as the newest revision. Based on the current generated notes, so restoring an
    /// older version never shows them as new notes waiting to replace it.
    public static func restoring(_ old: NotesDocumentRevision, currentSummaryID: RevisionID?, at date: Date = Date()) -> NotesDocumentRevision {
        NotesDocumentRevision(meetingID: old.meetingID, createdAt: date, basedOnSummaryRevisionID: currentSummaryID ?? old.basedOnSummaryRevisionID,
                              origin: .restored, blocks: old.blocks)
    }

    /// "Today 14:02 · Generated", "Oct 29, 09:15 · Edited".
    public static func versionLabel(_ r: NotesDocumentRevision, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = r.createdAt.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDate(r.createdAt, inSameDayAs: now) ? "Today"
            : calendar.isDate(r.createdAt, inSameDayAs: now.addingTimeInterval(-86_400)) ? "Yesterday"
            : r.createdAt.formatted(.dateTime.month(.abbreviated).day())
        let what = switch r.origin { case .generated: "Generated"; case .edited: "Edited"; case .restored: "Restored"; case .migrated: "Before one notes field" }
        return "\(day) \(time) · \(what)"
    }
}
