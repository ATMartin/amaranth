public import Foundation

/// Evidence that something was said, pointing into a specific transcript revision.
public struct TranscriptEvidence: Hashable, Sendable, Codable {
    public var revisionID: RevisionID
    public var segmentID: TranscriptSegmentID
    /// Inclusive word span within the segment.
    public var firstWord: WordID
    public var lastWord: WordID

    public init(revisionID: RevisionID, segmentID: TranscriptSegmentID, firstWord: WordID, lastWord: WordID) {
        self.revisionID = revisionID
        self.segmentID = segmentID
        self.firstWord = firstWord
        self.lastWord = lastWord
    }
}

/// Evidence from the user's private scratchpad. A distinct type so it can never masquerade as speech.
public struct ScratchpadEvidence: Hashable, Sendable, Codable {
    public var revisionID: RevisionID
    /// UTF-16 offsets into the scratchpad revision text, half-open.
    public var start: Int
    public var end: Int

    public init(revisionID: RevisionID, start: Int, end: Int) {
        self.revisionID = revisionID
        self.start = start
        self.end = end
    }
}

public enum EvidenceRef: Hashable, Sendable, Codable {
    case transcript(TranscriptEvidence)
    /// A line the user wrote in the meeting's notes document (spec 0008).
    case userNote(NoteEvidence)
    /// Before spec 0008: the private scratchpad. Still decodable so v5 libraries migrate; never produced.
    case personalNote(ScratchpadEvidence)

    public var isSpoken: Bool { if case .transcript = self { true } else { false } }
}

/// Relative date text is kept verbatim; `normalized` is set only when interpretation is unambiguous.
public struct DueDate: Hashable, Sendable, Codable {
    public var originalText: String
    public var normalized: Date?
    public init(originalText: String, normalized: Date? = nil) {
        self.originalText = originalText
        self.normalized = normalized
    }
}

public enum SummaryItemKind: String, Hashable, Sendable, Codable {
    case overview, topic, decision, actionItem, openQuestion, limitation
}

public struct SummaryItem: Hashable, Sendable, Codable, Identifiable {
    public var id: SummaryItemID
    public var kind: SummaryItemKind
    /// Topic heading, when `kind == .topic`.
    public var title: String?
    public var text: String
    public var evidence: [EvidenceRef]
    /// Populated only when the conversation supports it. `nil` means unknown, not "nobody".
    public var owner: String?
    public var ownerEvidence: [EvidenceRef]
    public var due: DueDate?
    /// Validator could not fully confirm support; shown with an uncertainty marker.
    public var uncertain: Bool

    public init(id: SummaryItemID = SummaryItemID(), kind: SummaryItemKind, title: String? = nil, text: String,
                evidence: [EvidenceRef], owner: String? = nil, ownerEvidence: [EvidenceRef] = [],
                due: DueDate? = nil, uncertain: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.evidence = evidence
        self.owner = owner
        self.ownerEvidence = ownerEvidence
        self.due = due
        self.uncertain = uncertain
    }
}

public struct SummaryContent: Hashable, Sendable, Codable {
    public var overview: [SummaryItem]
    public var topics: [SummaryItem]
    public var decisions: [SummaryItem]
    public var actionItems: [SummaryItem]
    public var openQuestions: [SummaryItem]
    public var limitations: [SummaryItem]

    public init(overview: [SummaryItem] = [], topics: [SummaryItem] = [], decisions: [SummaryItem] = [],
                actionItems: [SummaryItem] = [], openQuestions: [SummaryItem] = [], limitations: [SummaryItem] = []) {
        self.overview = overview
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.limitations = limitations
    }

    public var allItems: [SummaryItem] { overview + topics + decisions + actionItems + openQuestions + limitations }
}

public enum SummaryValidationStatus: String, Hashable, Sendable, Codable {
    case valid
    /// Some items were dropped or marked uncertain by evidence validation.
    case validWithOmissions
    case failed
}

public struct SummaryValidationReport: Hashable, Sendable, Codable {
    public var status: SummaryValidationStatus
    public var droppedItemCount: Int
    public var uncertainItemCount: Int
    public var repairAttempted: Bool
    public var messages: [String]

    public init(status: SummaryValidationStatus, droppedItemCount: Int = 0, uncertainItemCount: Int = 0,
                repairAttempted: Bool = false, messages: [String] = []) {
        self.status = status
        self.droppedItemCount = droppedItemCount
        self.uncertainItemCount = uncertainItemCount
        self.repairAttempted = repairAttempted
        self.messages = messages
    }
}

/// An immutable generated-notes revision: the record of what the model produced. Published atomically; a failed
/// regeneration never replaces a usable prior version. What the user sees and edits is the notes document composed from
/// it (spec 0008).
public struct SummaryRevision: Hashable, Sendable, Codable, Identifiable {
    public var id: RevisionID
    public var meetingID: MeetingID
    public var transcriptRevisionID: RevisionID
    /// Highest `UserEdit.sequence` reflected in the input snapshot (0 = no edits).
    public var editSequence: Int
    public var createdAt: Date
    public var producer: ProducerInfo
    public var promptVersion: String
    public var content: SummaryContent
    public var validation: SummaryValidationReport
    /// Set when underlying transcript/attribution changed after generation.
    public var isStale: Bool
    /// Before spec 0008: the included scratchpad revision. Never set now; kept so old revisions decode.
    public var scratchpadRevisionID: RevisionID?
    /// Before spec 0008: the scratchpad was included. Never set now; kept so old revisions decode.
    public var influencedByPersonalNotes: Bool
    /// The notes document revision generation read (its snapshot): user lines cited as `.userNote` belong to it, and
    /// publishing compares it with the current document (spec 0008 §4).
    public var notesRevisionID: RevisionID?

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, transcriptRevisionID: RevisionID,
                editSequence: Int, createdAt: Date, producer: ProducerInfo, promptVersion: String,
                content: SummaryContent, validation: SummaryValidationReport, isStale: Bool = false,
                scratchpadRevisionID: RevisionID? = nil, influencedByPersonalNotes: Bool = false, notesRevisionID: RevisionID? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.transcriptRevisionID = transcriptRevisionID
        self.editSequence = editSequence
        self.createdAt = createdAt
        self.producer = producer
        self.promptVersion = promptVersion
        self.content = content
        self.validation = validation
        self.isStale = isStale
        self.scratchpadRevisionID = scratchpadRevisionID
        self.influencedByPersonalNotes = influencedByPersonalNotes
        self.notesRevisionID = notesRevisionID
    }

    /// The revision without references to a pre-0008 private scratchpad (its citations and switch), for exports: that
    /// text was never shared, and nothing points at it any more.
    public var withoutScratchpadReferences: SummaryRevision {
        var s = self
        func strip(_ items: [SummaryItem]) -> [SummaryItem] {
            items.map { var i = $0; i.evidence.removeAll { if case .personalNote = $0 { true } else { false } }
                        i.ownerEvidence.removeAll { if case .personalNote = $0 { true } else { false } }; return i }
        }
        s.content = SummaryContent(overview: strip(content.overview), topics: strip(content.topics), decisions: strip(content.decisions),
                                   actionItems: strip(content.actionItems), openQuestions: strip(content.openQuestions),
                                   limitations: content.limitations.filter { !$0.text.contains("your personal notes") })
        s.scratchpadRevisionID = nil
        s.influencedByPersonalNotes = false
        return s
    }

    /// Every evidence reference must resolve against the given transcript, or against a user block of the notes snapshot
    /// generation read (`notes`, whose ID must be `notesRevisionID`). Scratchpad evidence is never valid any more.
    public func validateReferences(transcript: TranscriptRevision, notes: NotesDocumentRevision? = nil) throws {
        guard transcript.id == transcriptRevisionID else {
            throw DomainError.invalidReference("summary targets \(transcriptRevisionID), got \(transcript.id)")
        }
        for item in content.allItems {
            if item.kind != .limitation, item.evidence.isEmpty {
                throw DomainError.invariantViolated("item \(item.id) has no evidence")
            }
            for ref in item.evidence + item.ownerEvidence {
                switch ref {
                case .transcript(let e):
                    guard e.revisionID == transcript.id, let seg = transcript.segment(e.segmentID),
                          let a = seg.words.firstIndex(where: { $0.id == e.firstWord }),
                          let b = seg.words.firstIndex(where: { $0.id == e.lastWord }), a <= b
                    else { throw DomainError.invalidReference("item \(item.id) transcript evidence") }
                case .userNote(let e):
                    guard let notes, notes.id == notesRevisionID, e.revisionID == notes.id,
                          notes.blocks.contains(where: { $0.id == e.blockID && $0.isUser })
                    else { throw DomainError.invalidReference("item \(item.id) user-note evidence") }
                case .personalNote:
                    throw DomainError.invalidReference("item \(item.id) scratchpad evidence")
                }
            }
        }
    }
}

/// Private scratchpad. Never appended invisibly to the transcript; excluded from summaries and exports
/// unless explicitly included.
public struct ScratchpadRevision: Hashable, Sendable, Codable, Identifiable {
    public var id: RevisionID
    public var meetingID: MeetingID
    public var text: String
    public var includeInSummary: Bool
    public var createdAt: Date

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, text: String, includeInSummary: Bool = false,
                createdAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.includeInSummary = includeInSummary
        self.createdAt = createdAt
    }
}

/// User-authored note edits, stored apart from machine summary revisions.
public struct ManualNotesRevision: Hashable, Sendable, Codable, Identifiable {
    public var id: RevisionID
    public var meetingID: MeetingID
    public var basedOnSummaryRevisionID: RevisionID?
    public var markdown: String
    public var createdAt: Date

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, basedOnSummaryRevisionID: RevisionID?,
                markdown: String, createdAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.basedOnSummaryRevisionID = basedOnSummaryRevisionID
        self.markdown = markdown
        self.createdAt = createdAt
    }
}
