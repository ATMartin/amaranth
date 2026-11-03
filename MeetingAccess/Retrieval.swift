public import Foundation
public import Domain
public import Storage
import CryptoKit

// MARK: Scope, context, requests and responses (spec 0009 §2)

/// Which meetings a caller may see: the policy hook every operation applies *before* ranking or windowing. Milestone T
/// maps connection grants onto it; bulk export and tests use `.all` or explicit meetings/folders. A meeting outside
/// the scope is indistinguishable from a missing one.
public enum AccessScope: Sendable, Equatable {
    case all
    /// Fixed membership.
    case meetings(Set<MeetingID>)
    /// Meetings filed in these folders now (a meeting moved in later is included).
    case folders(Set<FolderID>)

    public func allows(_ id: MeetingID, folder: FolderID?) -> Bool {
        switch self {
        case .all: true
        case .meetings(let ids): ids.contains(id)
        case .folders(let f): folder.map(f.contains) ?? false
        }
    }
}

/// Cancellation and the request deadline, checked between bounded steps.
public struct AccessContext: Sendable {
    public var deadline: Date
    public var isCancelled: @Sendable () -> Bool

    public init(deadline: Date = Date().addingTimeInterval(AccessLimits.requestDeadline), isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) {
        self.deadline = deadline
        self.isCancelled = isCancelled
    }

    public func check() throws {
        if isCancelled() { throw AccessError.cancelled }
        if Date() > deadline { throw AccessError.deadlineExceeded }
    }
}

/// Meeting filters shared by listing and search. Start bounds are UTC, inclusive start and exclusive end.
public struct MeetingFilter: Codable, Sendable, Equatable {
    /// Case- and accent-insensitive substring of the title.
    public var title: String?
    public var folderID: String?
    /// Someone listed for the meeting (full name, or one word of it such as a first name). Not a claim they spoke.
    public var participant: String?
    public var startFrom: Date?
    public var startBefore: Date?
    public init(title: String? = nil, folderID: String? = nil, participant: String? = nil, startFrom: Date? = nil, startBefore: Date? = nil) {
        self.title = title; self.folderID = folderID; self.participant = participant; self.startFrom = startFrom; self.startBefore = startBefore
    }
}

public struct ListMeetingsRequest: Codable, Sendable, Equatable {
    public var filter: MeetingFilter
    public var cursor: String?
    /// 1…50, default 20.
    public var limit: Int?
    public init(filter: MeetingFilter = MeetingFilter(), cursor: String? = nil, limit: Int? = nil) { self.filter = filter; self.cursor = cursor; self.limit = limit }
}

public struct MeetingListing: Codable, Sendable, Equatable {
    public var meetingID: String
    public var title: String
    public var start: Date
    public var durationNs: Int64
    public var folder: MeetingSnapshot.FolderRef?
    public var people: [String]
    /// none, processing, failed, provisional, final
    public var transcript: String
    /// present, none
    public var notes: String
    /// present, deleted
    public var audio: String
    public var citation: String
    /// Set when the title, a name or the people list was shortened for this listing (get_meeting/export have them whole).
    public var shortened: Bool?
}

public struct ListMeetingsResponse: Codable, Sendable, Equatable {
    public var format = ExternalSchema.format + "-list"
    public var version = ExternalSchema.version
    public var meetings: [MeetingListing]
    /// Pass back for the next page; nil at the end.
    public var nextCursor: String?
    public var limitations: [String]
}

public struct SearchMeetingsRequest: Codable, Sendable, Equatable {
    public var query: String
    /// Only these meetings (at most 50).
    public var meetingIDs: [String]?
    public var filter: MeetingFilter
    public var cursor: String?
    /// 1…20 passages, default 10.
    public var limit: Int?
    public init(query: String, meetingIDs: [String]? = nil, filter: MeetingFilter = MeetingFilter(), cursor: String? = nil, limit: Int? = nil) {
        self.query = query; self.meetingIDs = meetingIDs; self.filter = filter; self.cursor = cursor; self.limit = limit
    }
}

public struct SearchPassage: Codable, Sendable, Equatable {
    public var rank: Int
    public var meetingID: String
    public var meetingTitle: String
    public var meetingStart: Date
    /// The transcript or notes revision the passage was read from (get_meeting gives the meeting's fingerprint).
    public var revision: String?
    /// transcript, notes (generated), userNote (written by a person, never something said)
    public var source: String
    public var ref: String
    /// Ranking signal within this search only: not a confidence or probability.
    public var score: Double
    public var lines: [Line]
    public var citation: String

    public struct Line: Codable, Sendable, Equatable {
        public var segmentID: String?
        public var wordID: String?
        public var blockID: String?
        public var startNs: Int64?
        public var speaker: String?
        public var text: String
        /// This line matched the query; the others are context.
        public var matched: Bool
        public var citation: String
        /// Set when `text` was shortened to fit the response (get_meeting returns the line in full).
        public var shortened: Bool?
    }
}

public struct SearchMeetingsResponse: Codable, Sendable, Equatable {
    public var format = ExternalSchema.format + "-search"
    public var version = ExternalSchema.version
    /// The words actually matched (lower-cased, simple word forms).
    public var terms: [String]
    public var passages: [SearchPassage]
    public var nextCursor: String?
    public var limitations: [String]
}

public struct GetMeetingRequest: Codable, Sendable, Equatable {
    public enum Section: String, Codable, Sendable, CaseIterable { case metadata, notes, transcript }
    public var meetingID: String
    public var section: Section
    /// Transcript only: lines overlapping [startNs, endNs).
    public var startNs: Int64?
    public var endNs: Int64?
    public var cursor: String?
    /// Fails with `changed` when the meeting's current fingerprint differs.
    public var expectedFingerprint: String?
    public init(meetingID: String, section: Section, startNs: Int64? = nil, endNs: Int64? = nil, cursor: String? = nil, expectedFingerprint: String? = nil) {
        self.meetingID = meetingID; self.section = section; self.startNs = startNs; self.endNs = endNs; self.cursor = cursor; self.expectedFingerprint = expectedFingerprint
    }
}

/// The snapshot's metadata, without the transcript and notes bodies, plus their sizes.
public struct MeetingMetadata: Codable, Sendable, Equatable {
    public var libraryID: String
    public var meetingID: String
    public var fingerprint: String
    public var readAt: Date
    public var title: String
    public var start: Date
    public var timeZone: String?
    public var durationNs: Int64
    public var folder: MeetingSnapshot.FolderRef?
    public var people: [String]
    public var state: MeetingSnapshot.ContentState
    public var revisions: MeetingSnapshot.Revisions
    public var generatedNotes: MeetingSnapshot.GeneratedNotesProvenance?
    public var speakers: [MeetingSnapshot.SpeakerRef]
    public var transcriptLineCount: Int
    public var notesLineCount: Int
    public var gapCount: Int
    public var limitations: [String]
    public var citation: String

    /// Set when the title, names or lists were shortened to keep the response within the budget.
    public var shortened: Bool?

    /// Metadata within fixed caps (`ProjectionCaps`), so the envelope always leaves room for content.
    public init(_ s: MeetingSnapshot) {
        var cut = false
        libraryID = s.libraryID; meetingID = s.meetingID; fingerprint = s.fingerprint; readAt = s.readAt; start = s.start
        title = ProjectionCaps.text(s.title, ProjectionCaps.title, &cut)
        timeZone = s.timeZone; durationNs = s.durationNs; state = s.state; revisions = s.revisions
        folder = s.folder.map { .init(id: $0.id, name: ProjectionCaps.text($0.name, ProjectionCaps.name, &cut)) }
        people = ProjectionCaps.names(s.people, &cut)
        if s.speakers.count > ProjectionCaps.listItems { cut = true }
        speakers = s.speakers.prefix(ProjectionCaps.listItems).map { .init(id: $0.id, name: ProjectionCaps.text($0.name, ProjectionCaps.name, &cut)) }
        generatedNotes = s.generatedNotes; transcriptLineCount = s.transcript.count; notesLineCount = s.notes.count
        gapCount = s.gaps.count; limitations = s.limitations; citation = s.citation
        if cut { shortened = true; limitations.append(ProjectionCaps.note) }
    }
}

public struct GetMeetingResponse: Codable, Sendable, Equatable {
    public var format = ExternalSchema.format + "-get"
    public var version = ExternalSchema.version
    public var section: GetMeetingRequest.Section
    public var meeting: MeetingMetadata
    public var transcript: [MeetingSnapshot.TranscriptLine]?
    public var gaps: [MeetingSnapshot.Gap]?
    public var notes: [MeetingSnapshot.NoteLine]?
    /// Set when the last item was too large for one response: its text here is a part; the cursor continues it.
    public var fragment: Fragment?
    public var nextCursor: String?

    public struct Fragment: Codable, Sendable, Equatable {
        /// Index of the item within the section (after any time-range filter).
        public var item: Int
        /// Character offsets of this part within the item's text.
        public var fromCharacter: Int
        public var toCharacter: Int
        public var complete: Bool
    }
}

/// Caps for metadata in list and get responses (spec 0009 §2): a title of 100,000 characters or 3,000 attendees must not
/// push a response past 64 KiB. Exports and snapshots keep everything.
public enum ProjectionCaps {
    public static let title = 512
    public static let name = 100
    public static let listItems = 50
    /// Longest line text in a search passage.
    public static let searchLine = 1_000
    public static let note = "Some titles, names or lists are shortened here (marked shortened); export the meeting for the full text."

    static func text(_ s: String, _ max: Int, _ cut: inout Bool) -> String {
        guard s.count > max else { return s }
        cut = true
        return String(s.prefix(max - 1)) + "…"
    }

    static func names(_ list: [String], _ cut: inout Bool) -> [String] {
        if list.count > listItems { cut = true }
        return list.prefix(listItems).map { text($0, name, &cut) }
    }
}

// MARK: Operations

extension MeetingReader {
    /// list_meetings: metadata and state of meetings in scope that match the filter, newest first (ties by ID).
    /// Never returns transcript or notes text.
    public func listMeetings(_ r: ListMeetingsRequest, scope: AccessScope = .all, context: AccessContext = AccessContext()) throws -> ListMeetingsResponse {
        let limit = try Self.bounded(r.limit, default: 20, max: AccessLimits.maxListRows, "limit")
        try Self.validate(r.filter)
        try context.check()
        let (generation, entries) = try store.meetingCatalog()
        let key = Self.requestKey("list", r.filter, nil, scope: scope)
        let offset = try r.cursor.map { try Cursor.decode($0, op: "list", key: key, generation: generation).offset } ?? 0
        let rows = Self.matching(entries, r.filter, scope: scope)
        var out = ListMeetingsResponse(meetings: rows.dropFirst(offset).prefix(limit).map(Self.listing), limitations: [])
        if r.filter.participant != nil { out.limitations.append(Self.participantNote) }
        if out.meetings.contains(where: { $0.shortened == true }) { out.limitations.append(ProjectionCaps.note) }
        // Fewer rows when long metadata would pass the budget; the cursor continues after the last row sent.
        while out.meetings.count > 1, try Self.size(out) > AccessLimits.maxResponseBytes - 512 { out.meetings.removeLast() }
        if offset + out.meetings.count < rows.count {
            out.nextCursor = Cursor(op: "list", key: key, generation: generation, offset: offset + out.meetings.count).encoded
        }
        try context.check()
        return out
    }

    /// search_meetings: ranked passages from current transcripts and notes in scope, with citations. Filters and scope
    /// are applied inside the full-text query, before ranking and context windows.
    public func searchMeetings(_ r: SearchMeetingsRequest, scope: AccessScope = .all, context: AccessContext = AccessContext()) throws -> SearchMeetingsResponse {
        let limit = try Self.bounded(r.limit, default: 10, max: AccessLimits.maxSearchPassages, "limit")
        let query = r.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.query.count <= AccessLimits.maxQueryCharacters else { throw AccessError.invalidRequest("query longer than \(AccessLimits.maxQueryCharacters) characters") }
        guard !query.isEmpty else { throw AccessError.badQuery("empty query: use list_meetings to browse") }
        if let ids = r.meetingIDs {
            guard ids.count <= AccessLimits.maxMeetingIDs else { throw AccessError.invalidRequest("more than \(AccessLimits.maxMeetingIDs) meetingIDs") }
            guard ids.allSatisfy(SourceURL.isIdentifier) else { throw AccessError.invalidRequest("meetingIDs") }
        }
        try Self.validate(r.filter)
        let terms = Retriever.terms(query)
        guard !terms.isEmpty else { throw AccessError.badQuery("no searchable words in the query") }
        try context.check()
        let (generation, entries) = try store.meetingCatalog()
        let key = Self.requestKey("search", r.filter, query + "\u{1F}" + (r.meetingIDs ?? []).sorted().joined(separator: ","), scope: scope)
        let offset = try r.cursor.map { try Cursor.decode($0, op: "search", key: key, generation: generation).offset } ?? 0
        var allowed = Set(Self.matching(entries, r.filter, scope: scope).map(\.meeting.id))
        if let ids = r.meetingIDs { allowed.formIntersection(ids.map { MeetingID($0) }) }
        var out = SearchMeetingsResponse(terms: terms, passages: [], limitations: Self.searchNotes(r.filter))
        guard !allowed.isEmpty, offset < Self.maxRankedPassages else { return out }

        // One ranking per request with fixed parameters, so every page is a slice of the same list (a candidate pool that
        // grew with the page number ranked later pages differently). Deep pages stop at `maxRankedPassages`.
        var retriever = Retriever(store: store, k: Self.maxRankedPassages)
        retriever.candidates = Self.searchCandidates
        let ranked = try retriever.search(query, meetings: allowed)
        try context.check()
        let starts = Dictionary(entries.map { ($0.meeting.id, Self.start($0.meeting)) }, uniquingKeysWith: { a, _ in a })
        var page: [SearchPassage] = []
        for (i, p) in ranked.enumerated().dropFirst(offset).prefix(limit) {
            try context.check()
            if let passage = Self.passage(p, rank: i + 1, start: starts[p.meetingID] ?? p.meetingDate) { page.append(passage) }
        }
        // Whole passages only: drop from the end until the response fits, and continue from the first dropped one.
        var next = ranked.count > offset + limit && offset + limit < Self.maxRankedPassages ? offset + limit : nil
        out.passages = page
        while out.passages.count > 1, try Self.size(out) > AccessLimits.maxResponseBytes - 512 {
            let dropped = out.passages.removeLast()
            next = dropped.rank - 1
        }
        out.nextCursor = next.map { Cursor(op: "search", key: key, generation: generation, offset: $0).encoded }
        if out.passages.contains(where: { $0.lines.contains { $0.shortened == true } }) {
            out.limitations.append("Lines longer than \(ProjectionCaps.searchLine) characters are shortened here (marked shortened); get_meeting returns them in full.")
        }
        if ranked.count >= Self.maxRankedPassages, next == nil { out.limitations.append("Only the first \(Self.maxRankedPassages) ranked passages can be paged; narrow the query or filters for more.") }
        return out
    }

    /// get_meeting: one section of a meeting's current snapshot, paged to the response budget. A too-large item comes
    /// in parts (`fragment`) rather than being cut silently.
    public func getMeeting(_ r: GetMeetingRequest, scope: AccessScope = .all, context: AccessContext = AccessContext()) throws -> GetMeetingResponse {
        guard SourceURL.isIdentifier(r.meetingID) else { throw AccessError.invalidRequest("meetingID") }
        if let a = r.startNs, let b = r.endNs, a >= b { throw AccessError.invalidRequest("startNs must be before endNs") }
        if (r.startNs != nil || r.endNs != nil) && r.section != .transcript { throw AccessError.invalidRequest("a time range applies to the transcript") }
        if let f = r.expectedFingerprint, !(f.count == 64 && f.allSatisfy(\.isHexDigit)) { throw AccessError.invalidRequest("expectedFingerprint") }
        try context.check()
        let id = MeetingID(r.meetingID)
        guard let snap = try snapshot(id), scope.allows(id, folder: snap.folder.map { FolderID($0.id) }) else { throw AccessError.unavailable }
        if let f = r.expectedFingerprint, f != snap.fingerprint { throw AccessError.changed(currentFingerprint: snap.fingerprint) }
        let key = Self.requestKey("get", nil, "\(r.meetingID)|\(r.section.rawValue)|\(r.startNs ?? -1)|\(r.endNs ?? -1)", scope: scope)
        var position = (item: 0, character: 0)
        if let c = r.cursor {
            let cur = try Cursor.decode(c, op: "get", key: key, generation: snap.fingerprint)
            position = (cur.offset, cur.character)
        }
        var out = GetMeetingResponse(section: r.section, meeting: MeetingMetadata(snap))
        switch r.section {
        case .metadata:
            return out
        case .notes:
            let (items, fragment, next) = try Self.page(snap.notes, from: position, budget: Self.itemBudget(out), context: context,
                                                        text: { $0.text }, setText: { $0.text = $1 })
            out.notes = items; out.fragment = fragment
            out.nextCursor = next.map { Cursor(op: "get", key: key, generation: snap.fingerprint, offset: $0.item, character: $0.character).encoded }
        case .transcript:
            let lo = r.startNs ?? .min, hi = r.endNs ?? .max
            let lines = snap.transcript.filter { $0.endNs > lo && $0.startNs < hi }
            if position.item == 0 && position.character == 0 { out.gaps = snap.gaps.filter { $0.endNs > lo && $0.startNs < hi } }
            let (items, fragment, next) = try Self.page(lines, from: position, budget: Self.itemBudget(out), context: context,
                                                        text: { $0.text }, setText: { $0.text = $1 })
            out.transcript = items; out.fragment = fragment
            out.nextCursor = next.map { Cursor(op: "get", key: key, generation: snap.fingerprint, offset: $0.item, character: $0.character).encoded }
        }
        return out
    }
}

// MARK: Helpers

extension MeetingReader {
    static let maxRankedPassages = 100
    /// FTS rows read before windowing and ranking; constant so pages agree.
    static let searchCandidates = 1_000
    static let participantNote = "Participant filters meetings by who was listed for them; it does not mean that person said a given passage."

    static func searchNotes(_ f: MeetingFilter) -> [String] {
        var notes = [
            "Search matches words and their simple forms, not meaning: a question worded differently from what was said can miss. Try other words or names.",
            "Results are ranked passages, not a complete list. For questions about everything in a period, list meetings and read them with get_meeting.",
            "The score only orders passages within this search; it is not a confidence.",
        ]
        if f.participant != nil { notes.append(participantNote) }
        return notes
    }

    static func bounded(_ v: Int?, default d: Int, max m: Int, _ name: String) throws -> Int {
        guard let v else { return d }
        guard (1...m).contains(v) else { throw AccessError.invalidRequest("\(name) must be 1…\(m)") }
        return v
    }

    static func validate(_ f: MeetingFilter) throws {
        if let t = f.title, t.count > 200 { throw AccessError.invalidRequest("title filter too long") }
        if let p = f.participant, p.count > 200 { throw AccessError.invalidRequest("participant filter too long") }
        if let id = f.folderID, !SourceURL.isIdentifier(id) { throw AccessError.invalidRequest("folderID") }
        if let a = f.startFrom, let b = f.startBefore, a >= b { throw AccessError.invalidRequest("startFrom must be before startBefore") }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func start(_ m: Meeting) -> Date { m.clock?.utcOrigin ?? m.createdAt }

    /// Entries in scope that match the filter, newest first, ties by ID (a stable order for paging).
    static func matching(_ entries: [MeetingCatalogEntry], _ f: MeetingFilter, scope: AccessScope) -> [MeetingCatalogEntry] {
        let title = f.title.map(fold).flatMap { $0.isEmpty ? nil : $0 }
        let person = f.participant.map(fold).flatMap { $0.isEmpty ? nil : $0 }
        return entries.filter { e in
            let m = e.meeting
            guard scope.allows(m.id, folder: m.folderID) else { return false }
            if let id = f.folderID, m.folderID?.rawValue != id { return false }
            if let title, !fold(m.title).contains(title) { return false }
            if let person, !m.people.contains(where: { p in
                let name = fold(p.name)
                return name == person || name.split(whereSeparator: \.isWhitespace).contains { $0 == person }
            }) { return false }
            let s = start(m)
            if let a = f.startFrom, s < a { return false }
            if let b = f.startBefore, s >= b { return false }
            return true
        }.sorted { (start($0.meeting), $1.meeting.id.rawValue) > (start($1.meeting), $0.meeting.id.rawValue) }
    }

    static func listing(_ e: MeetingCatalogEntry) -> MeetingListing {
        let m = e.meeting
        let transcript: String = if m.currentTranscriptRevisionID != nil { "final" }
            else if m.provisionalTranscriptRevisionID != nil { "provisional" }
            else if [.prepare, .transcribe].contains(where: { e.jobStates[$0] == .failed }) { "failed" }
            else if [.prepare, .transcribe].contains(where: { e.jobStates[$0].map { !$0.isTerminal } ?? false })
                        || [.preparing, .recording, .paused, .stopping].contains(m.captureState) { "processing" }
            else { "none" }
        var cut = false
        let title = ProjectionCaps.text(m.title, ProjectionCaps.title, &cut)
        let folder: MeetingSnapshot.FolderRef? = m.folderID.flatMap { id in e.folderName.map { .init(id: id.rawValue, name: ProjectionCaps.text($0, ProjectionCaps.name, &cut)) } }
        let people = ProjectionCaps.names(m.people.map(\.name), &cut)
        return MeetingListing(meetingID: m.id.rawValue, title: title, start: SnapshotBuilder.ms(start(m)), durationNs: m.duration.nanoseconds,
                              folder: folder, people: people, transcript: transcript, notes: e.hasNotesDocument ? "present" : "none",
                              audio: m.audio == .deletedByUser ? "deleted" : "present", citation: SourceURL(meetingID: m.id).string,
                              shortened: cut ? true : nil)
    }

    /// A retriever passage with citations. Everything comes from the search index, which holds the displayed content
    /// and is rewritten in the same transaction as every edit, so text and citations agree without decoding transcripts.
    static func passage(_ p: Passage, rank: Int, start: Date) -> SearchPassage? {
        let lines: [SearchPassage.Line] = p.lines.compactMap { l in
            switch p.source {
            case .transcript:
                guard let seg = l.segmentID, let rev = l.revisionID, let word = l.firstWord else { return nil }
                let url = SourceURL(meetingID: p.meetingID, source: .transcript, ref: seg.rawValue, word: word.rawValue, revision: rev.rawValue,
                                    hash: SourceURL.lineHash(l.text))
                var cut = false
                let text = ProjectionCaps.text(l.text, ProjectionCaps.searchLine, &cut)
                return .init(segmentID: seg.rawValue, wordID: word.rawValue, blockID: nil, startNs: l.start?.nanoseconds,
                             speaker: l.speaker.map { ProjectionCaps.text($0, ProjectionCaps.title, &cut) },
                             text: text, matched: l.matched, citation: url.string, shortened: cut ? true : nil)
            case .notes, .userNote:
                guard let rev = l.revisionID else { return nil }
                let url = SourceURL(meetingID: p.meetingID, source: p.source == .userNote ? .userNote : .notes, ref: p.ref, revision: rev.rawValue,
                                    hash: SourceURL.lineHash(l.text))
                var cut = false
                let text = ProjectionCaps.text(l.text, ProjectionCaps.searchLine, &cut)
                return .init(segmentID: nil, wordID: nil, blockID: p.ref, startNs: nil, speaker: nil, text: text, matched: true, citation: url.string,
                             shortened: cut ? true : nil)
            }
        }
        guard let first = lines.first(where: \.matched) ?? lines.first else { return nil }
        var cut = false
        return SearchPassage(rank: rank, meetingID: p.meetingID.rawValue, meetingTitle: ProjectionCaps.text(p.meetingTitle, ProjectionCaps.title, &cut), meetingStart: SnapshotBuilder.ms(start),
                             revision: p.lines.first?.revisionID?.rawValue, source: p.source.rawValue, ref: p.ref,
                             score: (p.score * 1000).rounded() / 1000, lines: lines, citation: first.citation)
    }

    /// One compact encoder for size checks (encoding doesn't mutate it, so sharing is safe).
    nonisolated(unsafe) static let sizer = ExternalCoding.encoder(pretty: false)
    static func size<T: Encodable>(_ v: T) throws -> Int { try sizer.encode(v).count }

    /// Bytes left for items once the envelope is encoded (with a margin for the cursor and fragment fields).
    static func itemBudget(_ envelope: GetMeetingResponse) throws -> Int {
        let budget = AccessLimits.maxResponseBytes - (try size(envelope)) - 1024
        // The capped metadata leaves well over this; anything less would page a character at a time.
        guard budget >= 4096 else { throw AccessError.internal("metadata too large for one response") }
        return budget
    }

    /// Items from `from` that fit in `budget` bytes. When the first item alone is too large, its text is split on a
    /// character boundary into the largest part that fits, and the cursor continues inside it.
    static func page<T: Encodable>(_ items: [T], from: (item: Int, character: Int), budget: Int, context: AccessContext,
                                   text: (T) -> String, setText: (inout T, String) -> Void)
        throws -> ([T], GetMeetingResponse.Fragment?, (item: Int, character: Int)?) {
        guard from.item < items.count else {
            if from.item > items.count { throw AccessError.restartRequired }
            return ([], nil, nil)
        }
        var out: [T] = []
        var used = 2
        var i = from.item
        var frag: GetMeetingResponse.Fragment?
        // Continue a fragmented item first; its last part may share the page with the items after it.
        if from.character > 0 {
            let (part, end, done) = try fragment(items[i], from: from.character, budget: budget, text: text, setText: setText)
            frag = GetMeetingResponse.Fragment(item: i, fromCharacter: from.character, toCharacter: end, complete: done)
            if !done { return ([part], frag, (i, end)) }
            out.append(part); used += try size(part) + 1; i += 1
        }
        while i < items.count {
            try context.check()
            let n = try size(items[i]) + 1
            if used + n <= budget { out.append(items[i]); used += n; i += 1; continue }
            if !out.isEmpty { return (out, frag, (i, 0)) }
            // A single item larger than the budget: send its first part.
            let (part, end, done) = try fragment(items[i], from: 0, budget: budget, text: text, setText: setText)
            let first = GetMeetingResponse.Fragment(item: i, fromCharacter: 0, toCharacter: end, complete: done)
            return ([part], first, done ? (i + 1 < items.count ? (i + 1, 0) : nil) : (i, end))
        }
        return (out, frag, nil)
    }

    static func fragment<T: Encodable>(_ item: T, from: Int, budget: Int, text: (T) -> String, setText: (inout T, String) -> Void) throws -> (T, Int, Bool) {
        let chars = Array(text(item))
        guard from < chars.count else { throw AccessError.restartRequired }
        var lo = from + 1, hi = chars.count, best = from + 1
        func candidate(_ end: Int) -> T { var c = item; setText(&c, String(chars[from..<end])); return c }
        while lo <= hi {
            let mid = (lo + hi) / 2
            if try size(candidate(mid)) <= budget { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (candidate(best), best, best == chars.count)
    }

    /// A stable digest of what a cursor is bound to: the operation, filters and query.
    /// The scope is part of it: a cursor made under one grant can't continue under another.
    static func requestKey(_ op: String, _ f: MeetingFilter?, _ extra: String?, scope: AccessScope) -> String {
        let data = (try? ExternalCoding.encoder(pretty: false).encode(f)) ?? Data()
        let scopeText: String = switch scope {
        case .all: "all"
        case .meetings(let ids): "m:" + ids.map(\.rawValue).sorted().joined(separator: ",")
        case .folders(let ids): "f:" + ids.map(\.rawValue).sorted().joined(separator: ",")
        }
        var h = SHA256()
        h.update(data: Data(op.utf8)); h.update(data: data); h.update(data: Data((extra ?? "").utf8)); h.update(data: Data(scopeText.utf8))
        return h.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Opaque page cursors: base64url JSON bound to an operation, a request digest and a generation (the library's
/// content generation, or for get_meeting the meeting's fingerprint). Anything else is a restart.
struct Cursor: Codable {
    var v = 1
    var op: String
    var key: String
    var generation: String
    var offset: Int
    var character: Int = 0

    init(op: String, key: String, generation: String, offset: Int, character: Int = 0) {
        self.op = op; self.key = key; self.generation = generation; self.offset = offset; self.character = character
    }

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String, op: String, key: String, generation: String) throws -> Cursor {
        guard s.utf8.count <= 512, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw AccessError.invalidRequest("cursor") }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let c = try? JSONDecoder().decode(Cursor.self, from: data), c.v == 1,
              c.offset >= 0, c.character >= 0 else { throw AccessError.invalidRequest("cursor") }
        guard c.op == op, c.key == key else { throw AccessError.invalidRequest("cursor belongs to another request") }
        guard c.generation == generation else { throw AccessError.restartRequired }
        return c
    }
}
