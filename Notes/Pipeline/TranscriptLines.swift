public import Foundation
public import Domain

/// A numbered, citable unit of the notes input: one speaker's consecutive words within one transcript segment, or one
/// paragraph of the user's personal notes (only when they opted in). Numbers are what the model cites as evidence.
public struct NotesLine: Hashable, Sendable, Codable {
    /// A contiguous word span inside one transcript segment.
    public struct Span: Hashable, Sendable, Codable {
        public var segment: TranscriptSegmentID
        public var firstWord: WordID
        public var lastWord: WordID
    }
    public enum Origin: Hashable, Sendable, Codable {
        /// One or more consecutive spans by the same speaker (merged so short turns don't waste tokens).
        case spoken([Span])
        case personalNote(start: Int, end: Int)   // UTF-16 offsets into the scratchpad text
    }
    public var id: Int
    public var origin: Origin
    /// Rendered speaker ("Speaker 2", a user-given name, "Unknown speaker") or "personal note".
    public var speaker: String
    public var text: String
    /// Session seconds; -1 for personal notes (they have no time).
    public var start: Double

    public var isPersonalNote: Bool { if case .personalNote = origin { true } else { false } }
}

/// Non-citable marker shown to the model in place of audio that has no text (so it knows the record is incomplete).
public struct NotesGap: Hashable, Sendable, Codable {
    public var start: Double
    public var seconds: Double
    public var reason: String
}

public struct NotesInputDocument: Sendable, Codable {
    public var lines: [NotesLine]
    public var gaps: [NotesGap]
    /// Personal-note line numbers start here so they can never collide with spoken lines.
    public static let personalNoteBase = 90_001

    public func line(_ id: Int) -> NotesLine? {
        if let i = index[id] { return lines[i] }
        return nil
    }
    private var index: [Int: Int]

    enum CodingKeys: String, CodingKey { case lines, gaps }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decode([NotesLine].self, forKey: .lines)
        gaps = try c.decode([NotesGap].self, forKey: .gaps)
        index = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.id, $0) })
    }

    public init(lines: [NotesLine], gaps: [NotesGap]) {
        self.lines = lines
        self.gaps = gaps
        index = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.id, $0) })
    }

    /// Splits segments at speaker changes, merges consecutive runs by the same speaker (pause < 3 s, ≤ `maxWords`) into
    /// one citable line, numbers lines in time order, and adds personal-note paragraphs only if
    /// `scratchpad?.includeInSummary` is true. Gaps ≥ `minGap` seconds of missing, untranscribed or paused audio become
    /// non-citable markers.
    public static func build(transcript: TranscriptRevision, scratchpad: ScratchpadRevision?, maxWords: Int = 80,
                             minGap: Double = 5) -> NotesInputDocument {
        let names = Dictionary(transcript.speakers.map { ($0.id, $0.displayName ?? $0.label) }, uniquingKeysWith: { a, _ in a })
        func label(_ a: SpeakerAssignment) -> String {
            switch a {
            case .unknown: "Unknown speaker"
            case .speaker(let id): names[id] ?? "Unknown speaker"
            case .multiple(let ids): ids.map { names[$0] ?? "?" }.joined(separator: " + ") + " (overlapping)"
            }
        }
        var runs: [(span: NotesLine.Span, speaker: String, words: [String], start: Double, end: Double)] = []
        for seg in transcript.segments.sorted(by: { $0.interval.start < $1.interval.start }) {
            var run: [Word] = []
            func flush() {
                guard let f = run.first, let l = run.last else { return }
                runs.append((NotesLine.Span(segment: seg.id, firstWord: f.id, lastWord: l.id), label(f.speaker),
                             run.map(\.text).filter { !$0.isEmpty }, f.interval.start.seconds, l.interval.end.seconds))
                run = []
            }
            for w in seg.words {
                if let f = run.first, label(f.speaker) != label(w.speaker) || run.count >= maxWords { flush() }
                run.append(w)
            }
            flush()
        }
        runs.sort { $0.start < $1.start }
        var lines: [NotesLine] = []
        var lastEnd = -Double.infinity, words = 0, lastAddressed = false
        for r in runs where !r.words.isEmpty {
            // Text addressed to an AI stays on its own line, so rejecting it never takes ordinary speech with it.
            let addressed = EvidenceChecker.looksAddressedToAI(r.words.joined(separator: " "))
            if !addressed, !lastAddressed, var last = lines.last, last.speaker == r.speaker, r.start - lastEnd < 3, words + r.words.count <= maxWords,
               case .spoken(let spans) = last.origin {
                last.origin = .spoken(spans + [r.span])
                last.text += " " + r.words.joined(separator: " ")
                lines[lines.count - 1] = last
                words += r.words.count
            } else {
                lines.append(NotesLine(id: lines.count + 1, origin: .spoken([r.span]), speaker: r.speaker, text: r.words.joined(separator: " "), start: r.start))
                words = r.words.count
            }
            lastEnd = max(lastEnd, r.end)
            lastAddressed = addressed
        }
        if let pad = scratchpad, pad.includeInSummary {
            var offset = 0, n = 0
            for para in pad.text.components(separatedBy: "\n") {
                let len = para.utf16.count
                let trimmed = para.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lines.append(NotesLine(id: personalNoteBase + n, origin: .personalNote(start: offset, end: offset + len),
                                           speaker: "personal note", text: trimmed, start: -1))
                    n += 1
                }
                offset += len + 1
            }
        }
        var gaps: [NotesGap] = []
        for c in transcript.coverage where c.interval.duration.seconds >= minGap {
            let reason: String? = switch c.status {
            case .missingAudio: "audio was not recorded"
            case .failed: "speech could not be transcribed"
            case .paused: "recording was paused"
            case .unsupportedLanguage: "speech in an unsupported language"
            default: nil
            }
            if let reason { gaps.append(NotesGap(start: c.interval.start.seconds, seconds: c.interval.duration.seconds, reason: reason)) }
        }
        return NotesInputDocument(lines: lines, gaps: gaps.sorted { $0.start < $1.start })
    }

    /// Prompt text for a run of lines, with gap markers interleaved at their times.
    public func render(_ chunk: ArraySlice<NotesLine>) -> String {
        var out: [String] = []
        let spoken = chunk.filter { !$0.isPersonalNote }
        let lo = spoken.first?.start ?? 0, hi = spoken.last?.start ?? 0
        var pending = gaps.filter { $0.start >= lo && $0.start <= hi }
        for l in chunk {
            while let g = pending.first, g.start <= l.start {
                out.append("[--] (no text: \(Int(g.seconds.rounded())) s, \(g.reason))")
                pending.removeFirst()
            }
            // No timestamps: the model doesn't need them and they cost tokens on every line.
            if l.isPersonalNote {
                out.append("[\(l.id)] (PERSONAL NOTE written by the user, not spoken) \(l.text)")
            } else {
                out.append("[\(l.id)] \(l.speaker): \(l.text)")
            }
        }
        return out.joined(separator: "\n")
    }

    public static func clockString(_ s: Double) -> String { clock(s) }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// Converts a cited line into contract evidence references (one per segment span it covers).
    public func evidence(_ id: Int, transcript: RevisionID, scratchpad: RevisionID?) -> [EvidenceRef] {
        guard let l = line(id) else { return [] }
        switch l.origin {
        case .spoken(let spans):
            return spans.map { .transcript(TranscriptEvidence(revisionID: transcript, segmentID: $0.segment, firstWord: $0.firstWord, lastWord: $0.lastWord)) }
        case .personalNote(let s, let e):
            guard let scratchpad else { return [] }
            return [.personalNote(ScratchpadEvidence(revisionID: scratchpad, start: s, end: e))]
        }
    }
}
