public import Foundation

/// Shown names in a scope (T113), from current content only: speakers (current shown names, incl. user renames) and
/// attendees (calendar people) per meeting. A transcript mention check is a separate lookup.
public struct NameDirectory: Sendable {
    public var speakers: [String: Set<MeetingID>]
    public var attendees: [String: Set<MeetingID>]
    public var meetingsInScope: Set<MeetingID>
    /// Shown names of personal-mic speakers (T119; also listed in `speakers`): the user unless renamed to someone else.
    public var localUserSpeakers: [String: Set<MeetingID>]
    public init(speakers: [String: Set<MeetingID>], attendees: [String: Set<MeetingID>], meetingsInScope: Set<MeetingID>,
                localUserSpeakers: [String: Set<MeetingID>] = [:]) {
        self.speakers = speakers; self.attendees = attendees; self.meetingsInScope = meetingsInScope; self.localUserSpeakers = localUserSpeakers
    }
}

/// The deterministic constraints of one request (T113): meeting-date range and people, with what had to be qualified.
public struct ResolvedConstraints: Hashable, Sendable, Codable {
    public var dateRange: MeetingDateRange?
    /// The range came from the previous turn (follow-up without its own time phrase).
    public var dateInherited: Bool
    public var people: [ResolvedPerson]
    /// Meetings where the user is a known speaker (“Me”), with that speaker's shown name.
    public var selfSpeakers: [MeetingID: String]
    /// Meetings in scope where the question asks about the user but no speaker is theirs (their lines can't be told apart).
    public var selfUnmappedMeetings: Int = 0
    public init(dateRange: MeetingDateRange? = nil, dateInherited: Bool = false, people: [ResolvedPerson] = [], selfSpeakers: [MeetingID: String] = [:]) {
        self.dateRange = dateRange; self.dateInherited = dateInherited; self.people = people; self.selfSpeakers = selfSpeakers
    }
    /// Asks about the user's own words with no trustworthy mapping in some meetings: answer by speaker label, qualified.
    public var selfUnmapped: Bool { people.contains { $0.resolution == .selfUnmapped } }
    public var ambiguous: [ResolvedPerson] { people.filter { $0.resolution == .ambiguous } }
}

public enum ConstraintResolver {
    /// Shown names the user gave themself.
    public static func isSelfName(_ name: String, accountName: String?) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if ["me", "myself", "me (you)", "you"].contains(n) { return true }
        if let a = accountName?.lowercased(), !a.isEmpty, n == a { return true }
        return false
    }

    /// Whether a personal-mic speaker shown as `name` is still the user: a self name, the default name for the user
    /// (`Speaker.localUserName`) or the first name of the account. Any other name means the user renamed it to someone else.
    public static func isLocalUserName(_ name: String, accountName: String?) -> Bool {
        if isSelfName(name, accountName: accountName) { return true }
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n == Speaker.localUserName.lowercased() { return true }
        if let first = accountName?.split(separator: " ").first?.lowercased(), !first.isEmpty, n == first { return true }
        return false
    }

    /// `previous`: the constraints of the turn this question follows (nil when it's not a follow-up). A new time phrase
    /// replaces the old one; without one a follow-up keeps it. People come from the validated plan and are resolved
    /// against `directory`; `mentioned(name)` says whether current transcript or notes text in scope contains the name.
    public static func resolve(question: String, plan: QueryPlan, now: Date, timeZone: TimeZone, previous: ResolvedConstraints?,
                               directory: NameDirectory, accountName: String?, mentioned: (String) -> Bool) -> ResolvedConstraints {
        var out = ResolvedConstraints()
        if let m = DateResolver.resolve(question, now: now, timeZone: timeZone) {
            out.dateRange = m.range
        } else if let t = plan.meetingTime, let m = DateResolver.resolve(t, now: now, timeZone: timeZone) {
            out.dateRange = m.range
        } else if let p = previous?.dateRange {
            out.dateRange = p; out.dateInherited = true
        }
        // The user's own speakers.
        for (name, ms) in directory.speakers where isSelfName(name, accountName: accountName) {
            for m in ms { out.selfSpeakers[m] = name }
        }
        // The personal-mic speaker (T119) is the user under its default name or a rename to the user's first name.
        for (name, ms) in directory.localUserSpeakers where isLocalUserName(name, accountName: accountName) {
            for m in ms where out.selfSpeakers[m] == nil { out.selfSpeakers[m] = name }
        }
        var seen = Set<String>()
        for p in plan.people where seen.insert(p.name.lowercased()).inserted {
            if p.role == .selfUser {
                // Mapped where a meeting has the user's own speaker; other meetings stay unattributable (counted, stated).
                let mapped = directory.meetingsInScope.filter { out.selfSpeakers[$0] != nil }
                out.selfUnmappedMeetings = directory.meetingsInScope.count - mapped.count
                out.people.append(ResolvedPerson(name: "I", role: .selfUser, resolution: mapped.isEmpty ? .selfUnmapped : .selfMapped,
                                                 speakerNames: Array(Set(mapped.compactMap { out.selfSpeakers[$0] })).sorted()))
                continue
            }
            let key = p.name.lowercased()
            let tokens = key.split(separator: " ").map(String.init)
            // An anonymous label (“Speaker 2”) names that label in each meeting; labels are per meeting, never one person.
            if tokens.count == 2, tokens[0] == "speaker", Int(tokens[1]) != nil {
                out.people.append(ResolvedPerson(name: p.name, role: p.role, resolution: .speaker, speakerNames: ["Speaker \(tokens[1])"]))
                continue
            }
            // A shown speaker name matches if it equals the name or its first name does (“Andrew” ~ “Andrew Kim”).
            let matches = directory.speakers.keys.filter { shown in
                let s = shown.lowercased()
                if isSelfName(shown, accountName: accountName) { return false }
                return s == key || s.split(separator: " ").first.map(String.init) == tokens.first && (tokens.count == 1 || s == key)
            }.sorted()
            let resolution: ResolvedPerson.Resolution
            if matches.count > 1 { resolution = .ambiguous }
            else if matches.count == 1 { resolution = .speaker }
            else if directory.attendees.keys.contains(where: { $0.lowercased() == key || $0.lowercased().split(separator: " ").first.map(String.init) == key }) || mentioned(p.name) {
                resolution = .mentionedOnly
            } else { resolution = .unknown }
            out.people.append(ResolvedPerson(name: p.name, role: p.role, resolution: resolution, speakerNames: matches))
        }
        return out
    }
}
