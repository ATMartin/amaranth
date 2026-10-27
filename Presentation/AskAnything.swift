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
