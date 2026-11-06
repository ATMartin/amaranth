public import Foundation
public import Domain
public import Storage
public import Contextual

/// Contextual Ask (spec 0010, T115): turns retrieved evidence into the answer request, the deterministic "search
/// facts" the model must follow, the notes shown with the answer, and the stage copy of the loading view.
public enum ContextualAsk {
    public enum Decision: Sendable {
        /// Ask the model: the request (passages in date order with their ranks) and the passages in prompt order
        /// (citation n is `passages[n - 1]`).
        case answer(AnswerRequest, passages: [Passage])
        /// The question needs the user to choose before an answer could be right.
        case clarify(String)
        /// Searched; nothing in scope supports an answer (not proof it wasn't discussed).
        case noEvidence(String)
    }

    public static func compose(_ e: ContextualEvidence, request: ContextualRequest, requestID: String) -> Decision {
        if let a = e.constraints.ambiguous.first(where: { $0.role == .speaker }) {
            let names = a.speakerNames.map { "“\($0)”" }
            return .clarify("Which \(a.name) do you mean? There are speakers named \(names.dropLast().joined(separator: ", "))\(names.count > 1 ? " and " : "")\(names.last ?? "") in these meetings. Ask again with the full name.")
        }
        guard !e.passages.isEmpty else {
            return .noEvidence(e.scopeMeetings == 0 ? "No meetings match \(rangePhrase(e.constraints) ?? "this scope"), so nothing was searched."
                                                    : "I couldn't find that in the meetings searched.")
        }
        // Date order (so a later change comes after what it changes); ranks decide what fits the prompt.
        let ordered = e.passages.sorted {
            ($0.passage.meetingDate, $0.passage.lines.first?.start?.nanoseconds ?? 0, $0.rank) < ($1.passage.meetingDate, $1.passage.lines.first?.start?.nanoseconds ?? 0, $1.rank)
        }
        let rendered = AskPassages.render(ordered.map(\.passage), acrossMeetings: true)
        let passages = zip(rendered, ordered).map { AnswerPassage(label: $0.label, text: $0.text, rank: $1.rank) }
        return .answer(AnswerRequest(requestID: requestID, question: modelQuestion(request.question, e.constraints), passages: passages, history: request.history,
                                     guidance: guidance(e, timeZone: TimeZone(identifier: request.timeZoneIdentifier) ?? .current)),
                       passages: ordered.map(\.passage))
    }

    /// The question as the model sees it: when the user isn't matched to a speaker, “I/me/my” become neutral (“each
    /// speaker”), so the model lists commitments by speaker instead of attributing them to the user; when the user is
    /// a known speaker, they become that speaker's name.
    public static func modelQuestion(_ q: String, _ c: ResolvedConstraints) -> String {
        guard let selfPerson = c.people.first(where: { $0.role == .selfUser }) else { return q }
        let mapped = selfPerson.resolution == .selfMapped ? (selfPerson.speakerNames.first ?? "Me") : nil
        let subject = mapped.map { "\($0) (the user)" } ?? "each speaker"
        let table: [(String, String)] = [("I'd", "\(subject) would"), ("I'll", "\(subject) will"), ("I've", "\(subject) has"), ("I'm", "\(subject) is"),
                                         ("I", subject), ("me", mapped ?? "them"), ("my", mapped.map { "\($0)'s" } ?? "the"), ("myself", mapped ?? "themselves"), ("mine", mapped.map { "\($0)'s" } ?? "theirs")]
        var out = ""
        var word = ""
        func flush() {
            if !word.isEmpty { out += table.first { $0.0.lowercased() == word.lowercased() && ($0.0 != "I" || word == "I") }?.1 ?? word; word = "" }
        }
        for ch in q { if ch.isLetter || ch == "'" || ch == "’" { word.append(ch == "’" ? "'" : ch) } else { flush(); out.append(ch) } }
        flush()
        return out
    }

    /// Deterministic post-check of a checked answer: with the user unmatched, any first-person or “you” attribution is
    /// a wrong-person claim → a clarification instead of the answer.
    public static func attributionViolation(_ answer: String, _ c: ResolvedConstraints) -> String? {
        guard c.people.contains(where: { $0.role == .selfUser && $0.resolution == .selfUnmapped }) else { return nil }
        let pattern = #"(?i)(^|[\s,.;:"“(])(i|you|we)(\s+(promised|committed|said|agreed|offered|will|would|owe|need to|have to|should)\b|['’](ll|d|ve)\b)|(?i)\byour (commitments?|promises?|follow-ups?)\b"#
        guard answer.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return "I can't tell which speaker is you in these meetings, so I won't say what you promised. Rename your speaker to “Me”, or ask about a speaker, for example “What did Speaker 2 promise?”."
    }

    /// Deterministic facts for the model (never meeting content).
    public static func guidance(_ e: ContextualEvidence, timeZone: TimeZone) -> [String] {
        var g: [String] = []
        if let r = e.constraints.dateRange {
            g.append("Only meetings that started \(rangeText(r, timeZone: timeZone)) were searched (the question's “\(r.phrase)”).")
        }
        for p in e.constraints.people {
            switch (p.role, p.resolution) {
            case (.selfUser, .selfMapped):
                g.append("The user is the speaker shown as “\(p.speakerNames.first ?? "Me")”. “I”, “me” and “my” in the question mean that speaker; only lines starting “\(p.speakerNames.first ?? "Me"):” are the user's own words.")
                if e.constraints.selfUnmappedMeetings > 0 {
                    g.append("In \(e.constraints.selfUnmappedMeetings) other meeting(s) searched the user isn't matched to a speaker: don't attribute anything there to the user.")
                }
            case (.selfUser, _):
                g.append("The user hasn't been matched to a speaker. Still answer: list each commitment or statement found with its speaker label (for example “Speaker 2 said they would send…”), and end by saying you can't tell which of these speakers is the user. Never write “you promised”.")
            case (.speaker, .speaker):
                g.append("\(p.name) is a speaker label in these meetings: their own words are lines that start with “\(p.speakerNames.first ?? p.name):”.")
            case (_, .speaker):
                g.append("\(p.name) is also a speaker label here (lines starting “\(p.speakerNames.first ?? p.name):”); other speakers' lines that mention \(p.name) are about them.")
            case (.speaker, .mentionedOnly):
                g.append("\(p.name) is not a named speaker in these meetings, but lines that mention \(p.name) may answer the question. Still answer from them: say what was said about \(p.name) and by which speaker label, without claiming \(p.name) said it.")
            case (_, .mentionedOnly):
                g.append("\(p.name) is talked about in these meetings but isn't a named speaker.")
            case (.speaker, .unknown):
                g.append("\(p.name) does not appear in these meetings.")
            default: break
            }
        }
        return g
    }

    /// Notes shown with the answer: what was searched and what limits it.
    public static func notes(_ e: ContextualEvidence, timeZone: TimeZone) -> [String] {
        var n: [String] = []
        if let r = e.constraints.dateRange { n.append("Searched meetings from \(rangeText(r, timeZone: timeZone)) (“\(r.phrase)”).") }
        if !e.semantic {
            n.append(e.coverage.encoderAvailable ? "Matched by keywords only this time." : "Searched by keywords only: contextual search needs the search model.")
        } else if !e.coverage.complete, e.coverage.meetingsInScope > 0 {
            n.append("Contextual search covers \(e.coverage.meetingsIndexed) of \(e.coverage.meetingsInScope) meetings so far; the rest were searched by keywords.")
        }
        if e.planFallback { n.append("The question was searched as written (it couldn't be interpreted in time).") }
        if e.constraints.people.contains(where: { $0.role == .selfUser && $0.resolution != .selfMapped }) {
            n.append("Amaranth can't tell which speaker is you, so commitments are listed by speaker. Rename your speaker to “Me” to fix that.")
        }
        for p in e.constraints.people where p.role == .speaker && p.resolution == .mentionedOnly {
            n.append("\(p.name) isn't a named speaker here, so this covers what others said about \(p.name).")
        }
        return n
    }

    public static func stageText(_ s: AskStage) -> String {
        switch s {
        case .preparing: "Getting ready…"
        case .waitingForRecording: "Waiting for the recording to end…"
        case .loadingModel: "Waking up the model…"
        case .planning, .searching: "Looking through your conversations…"
        case .reading: "Reading the relevant moments…"
        case .answering: "Putting the answer together…"
        }
    }

    static func rangePhrase(_ c: ResolvedConstraints) -> String? { c.dateRange.map { "“\($0.phrase)”" } }

    public static func rangeText(_ r: MeetingDateRange, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let last = r.end.addingTimeInterval(-1)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        return cal.isDate(r.start, inSameDayAs: last) ? f.string(from: r.start) : "\(f.string(from: r.start)) to \(f.string(from: last))"
    }
}
