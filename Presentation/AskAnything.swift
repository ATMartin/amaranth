public import Domain
public import Storage

/// The “Ask anything” field (T52): what it searches and how its results panel is laid out and moved through with keys.
public enum AskScope: String, CaseIterable, Sendable {
    case thisMeeting = "This meeting"
    case allMeetings = "All meetings"
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
