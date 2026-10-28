public import Domain
public import Storage

/// The “Ask anything” field (T52): what it searches and how its results panel is laid out and moved through with keys.
public enum AskScope: String, CaseIterable, Sendable {
    case thisMeeting = "This meeting"
    /// The folder the sidebar shows (T42); offered only while a folder is shown.
    case thisFolder = "This folder"
    case allMeetings = "All meetings"

    /// The scope switch's options: “This folder” only while the sidebar shows a folder.
    public static func options(folderShown: Bool) -> [AskScope] { folderShown ? allCases : [.thisMeeting, .allMeetings] }

    /// Segment labels: three full labels don't fit the 250 pt Ask pane, so with “This folder” shown they shorten.
    public func label(short: Bool) -> String {
        guard short else { return rawValue }
        return switch self { case .thisMeeting: "Meeting"; case .thisFolder: "Folder"; case .allMeetings: "All" }
    }
}

public enum AskResults {
    /// One meeting's hits in the panel, in rank order.
    public struct Group: Equatable, Sendable {
        public var meetingID: MeetingID
        public var title: String
        public var hits: [SearchHit]
    }

    /// Hits grouped by meeting. Meetings are ordered by their best hit; hits keep their rank order within a meeting.
    public static func grouped(_ hits: [SearchHit]) -> [Group] {
        var groups: [Group] = []
        var index: [MeetingID: Int] = [:]
        for hit in hits {
            if let i = index[hit.meetingID] { groups[i].hits.append(hit); continue }
            index[hit.meetingID] = groups.count
            groups.append(Group(meetingID: hit.meetingID, title: hit.meetingTitle, hits: [hit]))
        }
        return groups
    }

    /// The hits in the order the panel shows them (what the arrow keys walk through).
    public static func flattened(_ groups: [Group]) -> [SearchHit] { groups.flatMap(\.hits) }

    /// ↑/↓ in the field: from nothing selected, ↓ picks the first hit and ↑ the last; otherwise move by one, clamped.
    public static func move(_ selected: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let selected else { return delta > 0 ? 0 : count - 1 }
        return min(max(selected + delta, 0), count - 1)
    }

    /// The scope actually searched: “This meeting” needs a meeting on screen.
    public static func effectiveScope(_ scope: AskScope, meeting: MeetingID?) -> MeetingID? {
        scope == .thisMeeting ? meeting : nil
    }

    /// The folder actually searched (T42): “This folder” needs a folder shown in the sidebar; otherwise all meetings.
    public static func effectiveFolder(_ scope: AskScope, folder: FolderID?) -> FolderID? {
        scope == .thisFolder ? folder : nil
    }

    /// Caption for a hit's kind: a transcript time, or which kind of text matched.
    public static func kindLabel(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .title: "title"
        case .transcript: hit.start.map { TranscriptRows.clock($0) } ?? "transcript"
        case .notes: "notes"
        case .userNotes: "your notes"
        case .speaker: "speaker"
        case .person: "people"
        }
    }
}

/// How retrieved passages are shown to the model and as citation chips (T54).
public enum AskPassages {
    /// The prompt's view of each passage: a label with the meeting and time, then its lines (“[12:34] Rochelle: …”).
    /// Across meetings the label names the meeting and its date; within one meeting the time is enough.
    public static func render(_ passages: [Passage], acrossMeetings: Bool) -> [AnswerPassage] {
        passages.map { p in
            AnswerPassage(label: label(p, acrossMeetings: acrossMeetings, withDate: true),
                          text: p.lines.map { line in
                              switch p.source {
                              case .notes: "Meeting notes: \(line.text)"
                              case .transcript:
                                  (line.start.map { "[\(TranscriptRows.clock($0))] " } ?? "") + (line.speaker.map { "\($0): " } ?? "Unknown speaker: ")
                                      + trimmed(line.text, to: line.matched ? 900 : 320)
                              }
                          }.joined(separator: "\n"))
        }
    }

    /// Long transcript lines (a minute of one speaker) are cut: matched lines keep more than context lines.
    static func trimmed(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    public static func label(_ p: Passage, acrossMeetings: Bool, withDate: Bool = false) -> String {
        let place = p.source == .notes ? "notes" : (p.lines.first(where: \.matched) ?? p.lines.first)?.start.map { TranscriptRows.clock($0) } ?? "transcript"
        guard acrossMeetings else { return place }
        let date = withDate ? " (" + p.meetingDate.formatted(date: .abbreviated, time: .omitted) + ")" : ""
        return "\(p.meetingTitle)\(date) · \(place)"
    }

    /// Where a citation jumps: the evidence of the passage's best line (transcript) or the note's first evidence.
    public static func jumpEvidence(_ p: Passage) -> TranscriptEvidence? {
        if p.source == .transcript, let seg = p.lines.first(where: \.matched)?.segmentID ?? p.lines.first?.segmentID,
           let e = p.evidence.first(where: { $0.segmentID == seg }) { return e }
        return p.evidence.first
    }
}

/// Follow-up questions (T55): which earlier turns go with a question, and what the retriever searches for.
public enum AskFollowUp {
    /// Turns kept as context for the model.
    public static let maxTurns = 3

    static let referring: Set<String> = ["it", "its", "that", "this", "those", "these", "they", "them", "their", "he", "him", "his",
                                         "she", "her", "hers", "there", "then", "one", "ones", "same", "else", "more"]

    /// A question that leans on the previous one: a pronoun or “that/then/there”, an opening “and/so/but/what about”, or
    /// almost no words of its own (“why?”, “when is it due?”).
    public static func isFollowUp(_ question: String) -> Bool {
        let words = question.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !words.isEmpty else { return false }
        if ["and", "so", "but", "also"].contains(words[0]) || question.lowercased().hasPrefix("what about") || question.lowercased().hasPrefix("how about") { return true }
        if words.contains(where: referring.contains) { return true }
        return Retriever.terms(question).filter { !Retriever.stopWords.contains($0) }.count <= 1
    }

    /// What to retrieve passages for: a follow-up also searches the question it follows, so “and when is it due?” finds
    /// the lines about the thing the previous question asked about.
    public static func retrievalQuery(_ question: String, history: [AnswerTurn]) -> String {
        guard let last = history.last, isFollowUp(question) else { return question }
        return last.question + " " + question
    }
}
