import CryptoKit
import Domain
import Foundation
import Storage

/// Milestone V fixtures (`Benchmarks/Contextual/FORMAT.md`): synthetic meetings + labeled questions, seeded into an
/// isolated library together with generic filler meetings. No real meeting text.
enum CtxFixtures {
    struct Edit: Codable { var op: String; var line: Int; var from: String?; var to: String? }
    struct NoteLine: Codable { var text: String; var author: String }
    struct FixtureMeeting: Codable {
        var key: String
        var title: String
        var start: String
        var speakers: [String]
        var people: [String]?
        var folder: String?
        var lines: [Line]
        var notes: [NoteLine]?
        var edits: [Edit]?
        var indexing: String?
        var deleted: Bool?
    }
    struct Line: Codable {
        var speaker: Int; var text: String
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            speaker = try c.decode(Int.self); text = try c.decode(String.self)
        }
        func encode(to encoder: any Encoder) throws { var c = encoder.unkeyedContainer(); try c.encode(speaker); try c.encode(text) }
    }
    struct Scope: Codable { var kind: String; var meeting: String?; var folder: String? }
    struct Span: Codable { var meeting: String; var lines: [Int] }
    struct NoteSpan: Codable { var meeting: String; var notes: [Int] }
    struct DateRange: Codable { var start: String; var end: String; var kind: String? }
    struct Question: Codable {
        var id: String
        var scenario: String
        var categories: [String]
        var question: String
        var request_time: String?
        var scope: Scope
        var follows: String?
        var expected_behavior: String
        var expected_meaning: String
        var required_points: [String]
        var required_spans: [Span]
        /// Evidence that exists only in a meeting's notes: note line indexes (block IDs "<key>-n<i>").
        var required_notes: [NoteSpan]?
        var forbidden: [String]?
        var expected_date_range: DateRange?
        var rationale: String?
    }
    struct FixtureSet: Codable {
        var version: Int
        var set: String
        var about: String?
        var reference_now: String
        var timezone: String
        var meetings: [FixtureMeeting]
        var questions: [Question]
    }

    /// What the seeded library looks like to the evaluators.
    struct Seeded {
        var store: MeetingStore
        var meetingIDs: [String: MeetingID]
        var folders: [String: FolderID]
        var unindexed: Set<MeetingID>
        var timeZone: TimeZone
        var referenceNow: Date
    }

    static func load(_ url: URL) throws -> FixtureSet { try JSONDecoder().decode(FixtureSet.self, from: Data(contentsOf: url)) }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    static func meetingID(_ key: String) -> MeetingID {
        let h = Array(SHA256.hash(data: Data(("amaranth-ctx:" + key).utf8)))
        let s = Array(h.prefix(16).map { String(format: "%02x", $0) }.joined())
        return MeetingID("\(String(s[0..<8]))-\(String(s[8..<12]))-4\(String(s[13..<16]))-8\(String(s[17..<20]))-\(String(s[20..<32]))")
    }

    static func segmentID(_ key: String, _ line: Int) -> String { "\(key)-s\(line)" }

    /// Seeds `set` plus `filler` generic meetings into a new library at `root`.
    static func seed(_ set: FixtureSet, root: URL, filler: Int = 40) throws -> Seeded {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try MeetingStore(root: root)
        let tz = TimeZone(identifier: set.timezone) ?? .current
        var ids: [String: MeetingID] = [:]
        var folders: [String: FolderID] = [:]
        var unindexed = Set<MeetingID>()
        for m in set.meetings {
            guard let start = date(m.start) else { throw DomainError.invariantViolated("bad start \(m.start) in \(m.key)") }
            var folder: FolderID?
            if let name = m.folder {
                if folders[name] == nil { folders[name] = try store.createFolder(name: name).id }
                folder = folders[name]
            }
            let id = try writeMeeting(store, key: m.key, title: m.title, start: start, tz: set.timezone, speakers: m.speakers,
                                      lines: m.lines.map { ($0.speaker, $0.text) }, people: m.people ?? [], folder: folder,
                                      notes: m.notes ?? [], edits: m.edits ?? [])
            ids[m.key] = id
            if m.indexing == "unindexed" { unindexed.insert(id) }
            if m.deleted == true { try store.tombstone(id) }
        }
        var r = FillerRNG(state: 7)
        let base = date("2026-10-01T09:00:00-04:00")!
        for i in 0..<filler {
            let lines = (0..<60).map { j in (j % 3, fillerLine(&r)) }
            let start = base.addingTimeInterval(Double(i) * 0.9 * 86_400)
            _ = try writeMeeting(store, key: "filler-\(i)", title: "Team sync \(i + 1)", start: start, tz: set.timezone,
                                 speakers: ["Speaker 1", "Speaker 2", "Speaker 3"], lines: lines, people: [fillerNames[i % fillerNames.count]],
                                 folder: nil, notes: [], edits: [])
        }
        let now = date(set.reference_now) ?? Date()
        return Seeded(store: store, meetingIDs: ids, folders: folders, unindexed: unindexed, timeZone: tz, referenceNow: now)
    }

    @discardableResult
    static func writeMeeting(_ store: MeetingStore, key: String, title: String, start: Date, tz: String, speakers: [String],
                             lines: [(Int, String)], people: [String], folder: FolderID?, notes: [NoteLine], edits: [Edit]) throws -> MeetingID {
        let m = meetingID(key)
        try store.upsertMeeting(Meeting(id: m, title: title, createdAt: start, clock: SessionClock(utcOrigin: start, timeZoneIdentifier: tz, hostTimeOriginNanos: 0),
                                        captureState: .captured, duration: .seconds(Double(max(lines.count, 1)) * 6), folderID: folder))
        if !people.isEmpty { try store.setPeople(people.map { Person(name: $0) }, for: m) }
        if !lines.isEmpty {
            let sp = speakers.enumerated().map { i, name in
                Speaker(id: SpeakerID("\(key)-sp\(i)"), label: "Speaker \(i + 1)",
                        displayName: name.hasPrefix("Speaker ") ? nil : name)
            }
            var t0 = 0.0
            let segs = lines.enumerated().map { i, line -> TranscriptSegment in
                let who = SpeakerAssignment.speaker(sp[min(max(line.0, 0), sp.count - 1)].id)
                let tokens = line.1.split(separator: " ")
                let words = tokens.enumerated().map { j, w in
                    Word(id: WordID("\(key)-s\(i)-w\(j)"), text: String(w), interval: .seconds(t0 + Double(j) * 0.3, t0 + Double(j) * 0.3 + 0.25),
                         source: .systemOutput, speaker: who)
                }
                let seg = TranscriptSegment(id: TranscriptSegmentID(segmentID(key, i)), source: .systemOutput,
                                            interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end), words: words, speaker: who)
                t0 += Double(tokens.count) * 0.3 + 0.6
                return seg
            }
            let t = TranscriptRevision(id: RevisionID("\(key)-rev1"), meetingID: m, kind: .final, stage: .attributed, createdAt: start,
                                       producer: ProducerInfo(component: "synthetic", configHash: "ctx"), segments: segs,
                                       coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, t0 + 1), status: .transcribed)], speakers: sp)
            try store.publishTranscript(t)
            var seq = 0
            for e in edits {
                guard segs.indices.contains(e.line) else { throw DomainError.invariantViolated("\(key): edit line \(e.line) out of range") }
                let seg = segs[e.line]
                seq += 1
                let op: EditOperation
                switch e.op {
                case "correct":
                    let from = (e.from ?? "").split(separator: " ").map(String.init)
                    let texts = seg.words.map(\.text)
                    guard !from.isEmpty, let at = (0...(max(0, texts.count - from.count))).first(where: { i in
                        i + from.count <= texts.count && zip(texts[i..<(i + from.count)], from).allSatisfy { norm($0) == norm($1) } }) else {
                        throw DomainError.invariantViolated("\(key): '\(e.from ?? "")' not in line \(e.line)")
                    }
                    op = .correctText(WordRange(revisionID: t.id, first: seg.words[at].id, last: seg.words[at + from.count - 1].id), replacement: e.to ?? "")
                case "delete_line":
                    op = .deleteText(WordRange(revisionID: t.id, first: seg.words.first!.id, last: seg.words.last!.id))
                case "trim_before":
                    op = .trimTranscript(start: seg.interval.start, end: nil)
                default: throw DomainError.invariantViolated("\(key): unknown edit \(e.op)")
                }
                try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: t.id, sequence: seq, createdAt: start.addingTimeInterval(3600), operation: op))
            }
        }
        if !notes.isEmpty {
            let blocks = notes.enumerated().map { i, n in
                NoteBlock(id: NoteBlockID("\(key)-n\(i)"), kind: .paragraph, text: n.text,
                          author: n.author == "user" ? .user(typedAt: nil) : .model(summaryItemID: nil, uncertain: false))
            }
            try store.saveNotesDocument(NotesDocumentRevision(meetingID: m, createdAt: start.addingTimeInterval(1800), origin: .edited, blocks: blocks))
        }
        return m
    }

    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }

    // MARK: Filler (generic chatter, distractor names and dates)

    struct FillerRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }
    static let fillerNames = ["Ana", "Ben", "Chloe", "Dev", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun"]
    static let fillerTopics = ["roadmap", "budget", "hiring plan", "design review", "sprint goals", "onboarding flow", "pricing page", "dashboard",
                               "data migration", "release notes", "support queue", "quarterly goals", "team rituals", "documentation", "mobile app",
                               "billing service", "search feature", "status page", "analytics", "customer survey"]
    static let fillerVerbs = ["looks fine for now", "needs another pass", "is a bit behind", "should wrap up soon", "came up again", "is on track",
                              "needs an owner", "was discussed briefly", "has a few open questions", "might slip a little"]
    static let fillerChatter = ["Okay, sounds good.", "Let me share my screen.", "Can everyone hear me?", "I think that makes sense.",
                                "We can take that offline.", "Good point.", "Let's move on.", "Any other questions?", "I'll write that down.", "Thanks, everyone."]

    static func fillerLine(_ r: inout FillerRNG) -> String {
        switch Int.random(in: 0..<4, using: &r) {
        case 0: return fillerChatter.randomElement(using: &r)!
        case 1: return "\(fillerNames.randomElement(using: &r)!) said the \(fillerTopics.randomElement(using: &r)!) \(fillerVerbs.randomElement(using: &r)!)."
        case 2: return "The \(fillerTopics.randomElement(using: &r)!) \(fillerVerbs.randomElement(using: &r)!) and the \(fillerTopics.randomElement(using: &r)!) \(fillerVerbs.randomElement(using: &r)!)."
        default: return "\(fillerNames.randomElement(using: &r)!) will follow up on the \(fillerTopics.randomElement(using: &r)!) next week."
        }
    }

    // MARK: Scoring helpers

    /// Each required span (or notes span) is one evidence piece; covered if any of its lines' segment IDs (or note block
    /// IDs) is in `retrieved`.
    static func allSpansCovered(_ q: Question, retrieved: Set<String>) -> (covered: Int, total: Int) {
        let pieces = q.required_spans.map { s in Set(s.lines.map { segmentID(s.meeting, $0) }) }
            + (q.required_notes ?? []).map { n in Set(n.notes.map { "\(n.meeting)-n\($0)" }) }
        return (pieces.filter { !$0.isDisjoint(with: retrieved) }.count, pieces.count)
    }

    static func scope(_ q: Question, _ s: Seeded) -> (meeting: MeetingID?, folder: FolderID?) {
        switch q.scope.kind {
        case "meeting": return (q.scope.meeting.flatMap { s.meetingIDs[$0] }, nil)
        case "folder": return (nil, q.scope.folder.flatMap { s.folders[$0] })
        default: return (nil, nil)
        }
    }
}
