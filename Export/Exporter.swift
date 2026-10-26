public import Foundation
public import Domain

/// What goes into an export. Defaults follow plan §11: the private scratchpad is excluded, audio is excluded.
public struct ExportOptions: Sendable, Hashable {
    public var includeNotes = true
    public var includeUserNotes = true
    /// The private scratchpad is exported only when explicitly selected.
    public var includeScratchpad = false
    public init() {}
}

/// The exact content an export is made from: the *selected* revisions, not whatever is newest.
public struct ExportInput: Sendable {
    public var meeting: Meeting
    public var transcript: TranscriptRevision
    public var summary: SummaryRevision?
    public var userNotes: ManualNotesRevision?
    public var scratchpad: ScratchpadRevision?
    public init(meeting: Meeting, transcript: TranscriptRevision, summary: SummaryRevision? = nil,
                userNotes: ManualNotesRevision? = nil, scratchpad: ScratchpadRevision? = nil) {
        self.meeting = meeting; self.transcript = transcript; self.summary = summary; self.userNotes = userNotes; self.scratchpad = scratchpad
    }
}

/// TXT / Markdown / versioned JSON exports (T11). Transcript lines carry session timestamps (and wall-clock time when
/// known), the speaker label shown in the app, and the source track. Unknown and overlapping speakers stay explicit;
/// audio without text is listed as a gap, never omitted. Notes are labelled when stale, uncertain, or influenced by
/// personal notes.
public enum Exporter {
    public static let jsonFormat = "amaranth-export"
    public static let jsonVersion = 1
    /// ISO-8601 with fractional seconds (UTC).
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    // MARK: Shared rendering

    struct Line { var start: SessionTime; var end: SessionTime; var speaker: String; var source: SourceKind; var text: String; var flags: [String] }

    static func speakerNames(_ t: TranscriptRevision) -> [SpeakerID: String] {
        Dictionary(t.speakers.map { ($0.id, $0.displayName ?? $0.label) }, uniquingKeysWith: { a, _ in a })
    }

    static func label(_ a: SpeakerAssignment, _ names: [SpeakerID: String]) -> String {
        switch a {
        case .unknown: "Unknown speaker"
        case .speaker(let id): names[id] ?? "Unknown speaker"
        case .multiple(let ids): ids.map { names[$0] ?? "?" }.joined(separator: " + ") + " (overlapping)"
        }
    }

    static func lines(_ t: TranscriptRevision) -> [Line] {
        let names = speakerNames(t)
        var out: [Line] = []
        for seg in t.segments.sorted(by: { $0.interval.start < $1.interval.start }) {
            var run: [Word] = []
            func flush() {
                guard let f = run.first, let l = run.last else { return }
                var flags: [String] = []
                if run.contains(where: { $0.flags.contains(.questionableText) }) { flags.append("possibly garbled") }
                if run.contains(where: { $0.flags.contains(.probableEchoDuplicate) }) { flags.append("probable echo") }
                out.append(Line(start: f.interval.start, end: l.interval.end, speaker: label(f.speaker, names), source: seg.source,
                                text: run.map(\.text).filter { !$0.isEmpty }.joined(separator: " "), flags: flags))
                run = []
            }
            for w in seg.words {
                if let f = run.first, label(f.speaker, names) != label(w.speaker, names) { flush() }
                run.append(w)
            }
            flush()
        }
        return out.sorted { $0.start < $1.start }
    }

    struct Gap { var start: SessionTime; var end: SessionTime; var source: SourceKind; var reason: String }

    static func gaps(_ t: TranscriptRevision) -> [Gap] {
        t.coverage.compactMap { c -> Gap? in
            let reason: String? = switch c.status {
            case .missingAudio: "audio not recorded"
            case .failed: "speech could not be transcribed"
            case .paused: "recording paused"
            case .unsupportedLanguage: "unsupported language"
            case .pending: "not yet transcribed"
            case .transcribed, .noSpeech: nil
            }
            guard let reason, c.interval.duration.seconds >= 1 else { return nil }
            return Gap(start: c.interval.start, end: c.interval.end, source: c.source, reason: reason)
        }.sorted { $0.start < $1.start }
    }

    static func clock(_ t: SessionTime) -> String {
        let s = Int(t.seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// "People: Ana, Ben" when the meeting lists anyone (T49); nil keeps exports without people unchanged.
    static func peopleLine(_ m: Meeting) -> String? {
        m.people.isEmpty ? nil : "People: " + m.people.map(\.name).joined(separator: ", ")
    }

    static func sourceName(_ s: SourceKind) -> String { s == .microphone ? "mic" : "system audio" }

    static func wallClock(_ m: Meeting) -> String? {
        guard let c = m.clock else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        f.timeZone = TimeZone(identifier: c.timeZoneIdentifier)
        return f.string(from: c.utcOrigin)
    }

    /// Timestamp of the first transcript evidence of an item (for "see [00:12:03]").
    static func evidenceTimes(_ item: SummaryItem, _ t: TranscriptRevision) -> [String] {
        item.evidence.compactMap { ref -> String? in
            switch ref {
            case .transcript(let e):
                guard let seg = t.segment(e.segmentID), let w = seg.words.first(where: { $0.id == e.firstWord }) else { return nil }
                return clock(w.interval.start)
            case .personalNote:
                return "personal note"
            }
        }
    }

    static func notesDisclosures(_ s: SummaryRevision, transcript: TranscriptRevision) -> [String] {
        var out = ["Generated locally from the transcript (\(s.promptVersion)); check important items against the cited times."]
        if s.transcriptRevisionID != transcript.id || s.isStale { out.append("These notes were generated from an earlier version of the transcript.") }
        if s.influencedByPersonalNotes { out.append("These notes also used the author's private personal notes, which were not spoken in the meeting.") }
        return out
    }

    static func items(_ s: SummaryRevision) -> [(String, [SummaryItem])] {
        [("Overview", s.content.overview), ("Decisions", s.content.decisions), ("Action items", s.content.actionItems),
         ("Open questions", s.content.openQuestions), ("Topics", s.content.topics), ("Limitations", s.content.limitations)]
            .filter { !$0.1.isEmpty }
    }

    static func describe(_ item: SummaryItem, _ t: TranscriptRevision) -> String {
        var s = (item.title.map { "\($0): " } ?? "") + item.text
        var extras: [String] = []
        if let o = item.owner { extras.append("owner: \(o)") }
        if let d = item.due { extras.append("due: \(d.originalText)") }
        if item.uncertain { extras.append("uncertain") }
        let times = evidenceTimes(item, t)
        if !times.isEmpty { extras.append("see " + times.prefix(3).joined(separator: ", ")) }
        if !extras.isEmpty { s += " (" + extras.joined(separator: "; ") + ")" }
        return s
    }

    /// Transcript lines and gap markers interleaved in time order.
    static func timeline(_ t: TranscriptRevision, line: (Line) -> String, gap: (Gap) -> String) -> [String] {
        var out: [String] = []
        var pending = gaps(t)
        for l in lines(t) {
            while let g = pending.first, g.start <= l.start { out.append(gap(g)); pending.removeFirst() }
            out.append(line(l))
        }
        out += pending.map(gap)
        return out
    }

    // MARK: Formats

    public static func text(_ input: ExportInput, options: ExportOptions = ExportOptions()) -> String {
        let t = input.transcript, m = input.meeting
        var out = [m.title.isEmpty ? "Meeting" : m.title]
        if let p = peopleLine(m) { out.append(p) }
        if let w = wallClock(m) { out.append("Recorded \(w)") }
        out.append("Duration \(clock(SessionTime(nanoseconds: m.duration.nanoseconds))); transcript revision \(t.id.rawValue)")
        out.append("")
        if options.includeNotes, let s = input.summary {
            out.append("NOTES")
            out += notesDisclosures(s, transcript: t).map { "  * \($0)" }
            for (title, list) in items(s) {
                out.append(""); out.append(title.uppercased())
                out += list.map { "  - " + describe($0, t) }
            }
            out.append("")
        }
        if options.includeUserNotes, let n = input.userNotes, !n.markdown.isEmpty {
            out += ["YOUR NOTES", n.markdown, ""]
        }
        if options.includeScratchpad, let p = input.scratchpad, !p.text.isEmpty {
            out += ["PRIVATE SCRATCHPAD (included by choice)", p.text, ""]
        }
        out.append("TRANSCRIPT")
        out += timeline(t, line: { l in
            "[\(clock(l.start))] \(l.speaker) (\(sourceName(l.source))): \(l.text)" + (l.flags.isEmpty ? "" : " [\(l.flags.joined(separator: ", "))]")
        }, gap: { g in "[\(clock(g.start))–\(clock(g.end))] (\(sourceName(g.source)): no transcript, \(g.reason))" })
        return out.joined(separator: "\n") + "\n"
    }

    public static func markdown(_ input: ExportInput, options: ExportOptions = ExportOptions()) -> String {
        let t = input.transcript, m = input.meeting
        /// Spoken or generated text is data: escape Markdown syntax so it can't become links, images, HTML or headings.
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s {
                switch ch {
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\\", "[", "]", "(", ")", "!", "*", "_", "`", "#", "|", "~": out += "\\" + String(ch)
                default: out.append(ch)
                }
            }
            return out
        }
        var out = ["# \(esc(m.title.isEmpty ? "Meeting" : m.title))", ""]
        if let p = peopleLine(m) { out += [esc(p), ""] }
        var meta: [String] = []
        if let w = wallClock(m) { meta.append("Recorded \(w)") }
        meta.append("Duration \(clock(SessionTime(nanoseconds: m.duration.nanoseconds)))")
        out += ["_" + meta.joined(separator: " · ") + "_", ""]
        if options.includeNotes, let s = input.summary {
            out.append("## Notes")
            out += notesDisclosures(s, transcript: t).map { "> \($0)" }
            for (title, list) in items(s) {
                out += ["", "### \(title)", ""]
                out += list.map { "- " + esc(describe($0, t)) }
            }
            out.append("")
        }
        if options.includeUserNotes, let n = input.userNotes, !n.markdown.isEmpty {
            out += ["## Your notes", "", n.markdown, ""]
        }
        if options.includeScratchpad, let p = input.scratchpad, !p.text.isEmpty {
            out += ["## Private scratchpad (included by choice)", "", esc(p.text), ""]
        }
        out += ["## Transcript", ""]
        out += timeline(t, line: { l in
            "**[\(clock(l.start))] \(esc(l.speaker))** _(\(sourceName(l.source)))_: \(esc(l.text))" + (l.flags.isEmpty ? "" : " _[\(l.flags.joined(separator: ", "))]_")
        }, gap: { g in "_[\(clock(g.start))–\(clock(g.end))] \(sourceName(g.source)): no transcript, \(g.reason)_" }).map { $0 + "  " }
        return out.joined(separator: "\n") + "\n"
    }

    /// Versioned JSON: the selected contract revisions verbatim plus a convenience speaker map and line list.
    public struct JSONDocument: Codable, Sendable {
        public var format: String
        public var version: Int
        public var exportedAt: Date
        public var meeting: Meeting
        public var speakers: [String: String]
        public var transcript: TranscriptRevision
        public var summary: SummaryRevision?
        public var userNotes: ManualNotesRevision?
        public var scratchpad: ScratchpadRevision?
    }

    public static func json(_ input: ExportInput, options: ExportOptions = ExportOptions(), exportedAt: Date = Date()) throws -> Data {
        let doc = JSONDocument(format: jsonFormat, version: jsonVersion, exportedAt: exportedAt, meeting: input.meeting,
                               speakers: Dictionary(input.transcript.speakers.map { ($0.id.rawValue, $0.displayName ?? $0.label) }, uniquingKeysWith: { a, _ in a }),
                               transcript: input.transcript, summary: options.includeNotes ? input.summary : nil,
                               userNotes: options.includeUserNotes ? input.userNotes : nil,
                               scratchpad: options.includeScratchpad ? input.scratchpad : nil)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return try e.encode(doc)
    }

    // MARK: Audio (only when explicitly selected)

    public struct AudioManifest: Codable, Sendable {
        public struct File: Codable, Sendable { public var path: String; public var source: SourceKind; public var start: SessionTime; public var end: SessionTime; public var sha256: String }
        public struct Gap: Codable, Sendable { public var source: SourceKind?; public var start: SessionTime; public var end: SessionTime; public var reason: String }
        public var format = "amaranth-audio-export"
        public var version = 1
        public var meetingID: MeetingID
        public var files: [File]
        public var gaps: [Gap]
    }

    /// Copies the original, lossless CAF segments into `folder` with a manifest of their session times and every gap.
    /// Gaps are listed, never filled with silence.
    public static func exportAudio(meetingDirectory: URL, meetingID: MeetingID, segments: [AudioSegmentRecord], events: [CaptureEvent],
                                   to folder: URL) throws -> AudioManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [AudioManifest.File] = []
        for s in segments.filter({ $0.state == .committed }).sorted(by: { ($0.source.rawValue, $0.interval.start) < ($1.source.rawValue, $1.interval.start) }) {
            let rel = "\(s.source.rawValue)/" + (s.relativePath.split(separator: "/").suffix(2).joined(separator: "-"))
            let dest = folder.appending(path: rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: meetingDirectory.appending(path: s.relativePath), to: dest)
            files.append(.init(path: rel, source: s.source, start: s.interval.start, end: s.interval.end, sha256: s.sha256))
        }
        let gaps = events.filter(\.isMissingAudio).map { AudioManifest.Gap(source: $0.source, start: $0.interval.start, end: $0.interval.end, reason: $0.reasonCode) }
        let manifest = AudioManifest(meetingID: meetingID, files: files, gaps: gaps)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(manifest).write(to: folder.appending(path: "manifest.json"), options: .atomic)
        return manifest
    }
}
