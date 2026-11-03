import Foundation
import CryptoKit
import Domain
import Storage

/// Deterministic synthetic meetings for the T98 evaluation and scale runs. No real meeting text.
enum Synthetic {
    /// A stable meeting ID (UUID form) from a key, so question files can name meetings.
    static func id(_ key: String) -> MeetingID {
        let h = Array(SHA256.hash(data: Data(("amaranth-eval:" + key).utf8)))
        let hex = h.prefix(16).map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return MeetingID("\(String(s[0..<8]))-\(String(s[8..<12]))-4\(String(s[13..<16]))-8\(String(s[17..<20]))-\(String(s[20..<32]))")
    }

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }

    static let names = ["Ana", "Ben", "Chloe", "Dev", "Eli", "Fay", "Gus", "Hana", "Ivo", "Jun"]
    static let topics = ["roadmap", "budget", "hiring plan", "design review", "sprint goals", "onboarding flow", "pricing page", "dashboard",
                         "data migration", "release notes", "support queue", "quarterly goals", "team rituals", "documentation", "mobile app",
                         "billing service", "search feature", "status page", "analytics", "customer survey"]
    static let verbs = ["looks fine for now", "needs another pass", "is a bit behind", "should wrap up soon", "came up again", "is on track",
                        "needs an owner", "was discussed briefly", "has a few open questions", "might slip a little"]
    static let fillers = ["okay sounds good", "let me share my screen", "can everyone hear me", "I think that makes sense", "we can take that offline",
                          "good point", "let's move on", "any other questions", "I'll write that down", "thanks everyone"]

    static func fillerLine(_ r: inout RNG) -> String {
        switch Int.random(in: 0..<4, using: &r) {
        case 0: return fillers.randomElement(using: &r)!
        case 1: return "\(names.randomElement(using: &r)!) said the \(topics.randomElement(using: &r)!) \(verbs.randomElement(using: &r)!)"
        case 2: return "the \(topics.randomElement(using: &r)!) \(verbs.randomElement(using: &r)!) and the \(topics.randomElement(using: &r)!) \(verbs.randomElement(using: &r)!)"
        default: return "\(names.randomElement(using: &r)!) will follow up on the \(topics.randomElement(using: &r)!) next week"
        }
    }

    /// Writes one meeting: `lines` as transcript segments `<key>-s<i>` (one speaker per line, alternating), optional
    /// user notes as blocks `<key>-n<i>`. Returns the transcript revision.
    @discardableResult
    static func meeting(_ store: MeetingStore, key: String, title: String, start: Date, lines: [String], people: [String] = [],
                        folder: FolderID? = nil, notes: [String] = []) throws -> TranscriptRevision? {
        let m = id(key)
        try store.upsertMeeting(Meeting(id: m, title: title, createdAt: start, clock: SessionClock(utcOrigin: start, timeZoneIdentifier: "UTC", hostTimeOriginNanos: 0),
                                        captureState: .captured, duration: .seconds(Double(max(lines.count, 1)) * 6), folderID: folder))
        if !people.isEmpty { try store.setPeople(people.map { Person(name: $0) }, for: m) }
        var revision: TranscriptRevision?
        if !lines.isEmpty {
            let speakers = [Speaker(id: SpeakerID("\(key)-a"), label: "Speaker 1"), Speaker(id: SpeakerID("\(key)-b"), label: "Speaker 2")]
            let segs = lines.enumerated().map { i, text in
                let who = SpeakerAssignment.speaker(speakers[i % 2].id)
                let words = text.split(separator: " ").enumerated().map { j, w in
                    Word(id: WordID("\(key)-s\(i)-w\(j)"), text: String(w), interval: .seconds(Double(i) * 6 + Double(j) * 0.3, Double(i) * 6 + Double(j) * 0.3 + 0.25),
                         source: .systemOutput, speaker: who)
                }
                return TranscriptSegment(id: TranscriptSegmentID("\(key)-s\(i)"), source: .systemOutput,
                                         interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end), words: words, speaker: who)
            }
            let t = TranscriptRevision(id: RevisionID("\(key)-rev1"), meetingID: m, kind: .final, stage: .attributed, createdAt: start,
                                       producer: ProducerInfo(component: "synthetic", configHash: "x"), segments: segs,
                                       coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, Double(lines.count) * 6), status: .transcribed)], speakers: speakers)
            try store.publishTranscript(t)
            revision = t
        }
        if !notes.isEmpty {
            let blocks = notes.enumerated().map { i, n in NoteBlock(id: NoteBlockID("\(key)-n\(i)"), kind: .paragraph, text: n, author: .user(typedAt: nil)) }
            try store.saveNotesDocument(NotesDocumentRevision(meetingID: m, createdAt: start, origin: .edited, blocks: blocks))
        }
        return revision
    }

    /// `facts` placed among filler lines at evenly spread positions; returns all lines and each fact's line index.
    static func weave(_ facts: [String], total: Int, _ r: inout RNG) -> (lines: [String], positions: [Int]) {
        var lines = (0..<total).map { _ in fillerLine(&r) }
        var positions: [Int] = []
        for (i, f) in facts.enumerated() {
            let p = (i + 1) * total / (facts.count + 1)
            lines[p] = f; positions.append(p)
        }
        return (lines, positions)
    }
}
