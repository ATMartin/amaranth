public import Foundation

public enum NoteBlockTag {}
/// Stable across revisions of one meeting's notes document: a block keeps its ID when it is edited, kept or restored.
public typealias NoteBlockID = Identifier<NoteBlockTag>

/// Evidence from a line the user wrote (spec 0008): one block of a notes document. A distinct kind so a user's line can
/// never pass for something said in the meeting.
public struct NoteEvidence: Hashable, Sendable, Codable {
    /// The notes document revision generation read (its snapshot).
    public var revisionID: RevisionID
    public var blockID: NoteBlockID

    public init(revisionID: RevisionID, blockID: NoteBlockID) {
        self.revisionID = revisionID
        self.blockID = blockID
    }
}

/// Who wrote a block. Editing a model block's text makes it the user's (see `NoteBlock.editing(text:)`).
public enum NoteAuthor: Hashable, Sendable, Codable {
    /// `typedAt`: seconds from the recording's start when the line was first typed during the recording; nil when typed after.
    case user(typedAt: TimeInterval?)
    /// Produced by generation. `summaryItemID` is nil for the section headings the composer adds.
    case model(summaryItemID: SummaryItemID?, uncertain: Bool)

    public var isUser: Bool { if case .user = self { true } else { false } }
}

/// The generated section a heading starts; blocks under it are styled by it (decisions with the sage edge, next steps
/// with their owner and date line, Limitations collapsed).
public enum NoteSection: String, Hashable, Sendable, Codable, CaseIterable {
    case overview, topics, decisions, nextSteps, openQuestions, limitations, alsoNoted

    /// Today's section titles (the notes pane before spec 0008).
    public var title: String {
        switch self {
        case .overview: "Meeting notes"
        case .topics: "Topics"
        case .decisions: "Decisions"
        case .nextSteps: "Next steps"
        case .openQuestions: "Still open"
        case .limitations: "Limitations"
        case .alsoNoted: "Also noted"
        }
    }
}

public struct NoteBlock: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable { case heading, paragraph, bullet }

    public var id: NoteBlockID
    public var kind: Kind
    public var text: String
    /// The secondary line under a next step ("Dana · by Friday"); editable like the text.
    public var detail: String?
    /// Set on the headings the composer writes; nil on everything else.
    public var section: NoteSection?
    public var author: NoteAuthor
    /// Source chips. Model blocks cite the transcript (or a user block); a model block the user edited keeps the chips
    /// they did not delete.
    public var evidence: [EvidenceRef]

    public init(id: NoteBlockID = NoteBlockID(), kind: Kind, text: String, detail: String? = nil, section: NoteSection? = nil,
                author: NoteAuthor, evidence: [EvidenceRef] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.section = section
        self.author = author
        self.evidence = evidence
    }

    public var isUser: Bool { author.isUser }
    public var isUncertain: Bool { if case .model(_, true) = author { true } else { false } }

    /// The block after the user changed its text or detail: a model block becomes the user's (its uncertain marker goes,
    /// its remaining evidence stays). A user block keeps its typed-at time.
    public func editing(text: String? = nil, detail: String?? = nil) -> NoteBlock {
        var b = self
        if let text { b.text = text }
        if let detail { b.detail = detail }
        guard b != self else { return self }
        if !isUser { b.author = .user(typedAt: nil) }
        return b
    }
}

/// How a revision came to be; used to tell whether the user changed the notes since they were last generated.
public enum NotesDocumentOrigin: String, Hashable, Sendable, Codable {
    /// Built when a v5 library was migrated (spec 0008 §8).
    case migrated
    /// Composed from a generation result.
    case generated
    /// Saved from the editor or the live Notes field.
    case edited
    /// A copy of an earlier revision, from Previous Versions.
    case restored
}

/// One meeting's notes (spec 0008): an immutable revision; the newest is current, and every save is a new revision.
/// Generated `SummaryRevision`s are still stored as the record of what the model produced; this is what the user sees.
public struct NotesDocumentRevision: Hashable, Sendable, Codable, Identifiable {
    public var id: RevisionID
    public var meetingID: MeetingID
    public var createdAt: Date
    /// The generated notes this document was last composed from (nil when the meeting has none yet).
    public var basedOnSummaryRevisionID: RevisionID?
    public var origin: NotesDocumentOrigin
    public var blocks: [NoteBlock]

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, createdAt: Date, basedOnSummaryRevisionID: RevisionID? = nil,
                origin: NotesDocumentOrigin, blocks: [NoteBlock]) {
        self.id = id
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.basedOnSummaryRevisionID = basedOnSummaryRevisionID
        self.origin = origin
        self.blocks = blocks
    }

    /// The user's lines with text: what generation reads (spec 0008 §1: only user blocks go into generation).
    public var userBlocks: [NoteBlock] { blocks.filter { $0.isUser && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    public var isEmpty: Bool { blocks.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Same blocks (ignoring revision ID, time and origin).
    public func hasSameContent(as other: NotesDocumentRevision?) -> Bool { blocks == (other?.blocks ?? []) }
}

/// Builds notes documents from generated notes and the user's lines (spec 0008 §3 and §8).
public enum NotesComposer {
    /// Generated sections as model blocks in today's order, then every user block no item cites, word for word and in
    /// document order, under "Also noted". Without generated notes the user's blocks are the whole document.
    public static func compose(summary: SummaryRevision?, userBlocks: [NoteBlock], meetingID: MeetingID, createdAt: Date,
                               origin: NotesDocumentOrigin = .generated) -> NotesDocumentRevision {
        var blocks = summary.map(modelBlocks) ?? []
        let cited = Set((summary?.content.allItems ?? []).flatMap { $0.evidence + $0.ownerEvidence }.compactMap { ref -> NoteBlockID? in
            if case .userNote(let n) = ref { n.blockID } else { nil }
        })
        let kept = userBlocks.filter { !cited.contains($0.id) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !kept.isEmpty {
            if !blocks.isEmpty {
                blocks.append(NoteBlock(kind: .heading, text: NoteSection.alsoNoted.title, section: .alsoNoted, author: .model(summaryItemID: nil, uncertain: false)))
            }
            blocks += kept
        }
        return NotesDocumentRevision(meetingID: meetingID, createdAt: createdAt, basedOnSummaryRevisionID: summary?.id, origin: origin, blocks: blocks)
    }

    /// The generated sections, styled as the notes pane showed them before spec 0008.
    public static func modelBlocks(_ s: SummaryRevision) -> [NoteBlock] {
        let c = s.content
        var out: [NoteBlock] = []
        func section(_ sec: NoteSection, _ items: [SummaryItem], _ kind: NoteBlock.Kind) {
            guard !items.isEmpty else { return }
            out.append(NoteBlock(kind: .heading, text: sec.title, section: sec, author: .model(summaryItemID: nil, uncertain: false)))
            for item in items {
                let text = [item.title, item.text].compactMap { $0 }.joined(separator: " — ")
                // Missing data is said, never filled in (next steps always show who and when, as before).
                let detail = item.kind == .actionItem || item.owner != nil || item.due != nil
                    ? "\(item.owner ?? "No owner stated")  ·  \(item.due?.originalText ?? "no date stated")" : nil
                // The item's ID names the block, so search and Ask refs stay the generated item's.
                out.append(NoteBlock(id: NoteBlockID(item.id.rawValue), kind: kind, text: text, detail: detail, author: .model(summaryItemID: item.id, uncertain: item.uncertain),
                                     evidence: item.evidence))   // as shown before; owner evidence stays in the SummaryRevision
            }
        }
        section(.overview, c.overview, .paragraph)
        section(.topics, c.topics, .bullet)
        section(.decisions, c.decisions, .paragraph)
        section(.nextSteps, c.actionItems, .bullet)
        section(.openQuestions, c.openQuestions, .bullet)
        section(.limitations, c.limitations, .bullet)
        return out
    }

    /// User blocks from plain text, one per non-empty line: "# " starts a heading, "- ", "* " or "• " a bullet.
    public static func userBlocks(fromText text: String, typedAt: TimeInterval? = nil) -> [NoteBlock] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                let body = line.drop { $0 == "#" }
                if body.first == " ", case let t = body.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                    return NoteBlock(kind: .heading, text: t, author: .user(typedAt: typedAt))
                }
            }
            for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
                let t = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return NoteBlock(kind: .bullet, text: t, author: .user(typedAt: typedAt)) }
            }
            return NoteBlock(kind: .paragraph, text: line, author: .user(typedAt: typedAt))
        }
    }
}
