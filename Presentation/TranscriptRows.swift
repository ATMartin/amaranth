public import Foundation
public import Domain

/// One displayed transcript row: a speaker's consecutive words within a segment, or a gap with no text.
public struct TranscriptRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case speech, gap(reason: String) }
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let overlap = Flags(rawValue: 1)
        public static let uncertainSpeaker = Flags(rawValue: 2)
        public static let questionableText = Flags(rawValue: 4)
        public static let probableEcho = Flags(rawValue: 8)
        public static let corrected = Flags(rawValue: 16)
    }

    public var id: String
    public var kind: Kind
    public var start: SessionTime
    public var end: SessionTime
    public var source: SourceKind
    public var assignment: SpeakerAssignment
    /// "Dana", "Speaker 2", "Unknown speaker", "Speaker 1 + Speaker 3 (overlapping)", or "" for gaps.
    public var speakerLabel: String
    public var text: String
    /// Word range in the revision (for edits and evidence); nil for gaps.
    public var range: WordRange?
    public var segmentID: TranscriptSegmentID?
    public var flags: Flags

    public var isGap: Bool { if case .gap = kind { true } else { false } }
}

public enum TranscriptRows {
    public static func label(_ a: SpeakerAssignment, names: [SpeakerID: String]) -> String {
        switch a {
        case .unknown: "Unknown speaker"
        case .speaker(let id): names[id] ?? "Unknown speaker"
        case .multiple(let ids): ids.map { names[$0] ?? "Unknown" }.joined(separator: " + ") + " (overlapping)"
        }
    }

    public static func gapReason(_ s: CoverageRegion.Status) -> String? {
        switch s {
        case .missingAudio: "Audio was not recorded"
        case .failed: "Speech here could not be transcribed"
        case .paused: "Recording paused"
        case .unsupportedLanguage: "Speech in an unsupported language"
        case .pending: "Not transcribed yet"
        case .transcribed, .noSpeech: nil
        }
    }

    /// Rows in time order from `revision` with text corrections from `edits` applied; gaps ≥ `minGap` seconds appear
    /// as their own rows so missing or untranscribed audio is never silently omitted.
    public static func build(_ revision: TranscriptRevision, edits: [UserEdit], minGap: Double = 1) -> [TranscriptRow] {
        let corrected = revision.applyingTextCorrections(edits)
        let correctedIDs = Set(edits.compactMap { e -> WordID? in
            if case .correctText(let r, _) = e.operation, e.conflict == .applied { r.first } else { nil }
        })
        let names = Dictionary(corrected.speakers.map { ($0.id, $0.shownName) }, uniquingKeysWith: { a, _ in a })
        var rows: [TranscriptRow] = []
        for seg in corrected.segments {
            var run: [Word] = []
            func flush() {
                guard let f = run.first, let l = run.last else { return }
                var flags: TranscriptRow.Flags = []
                if run.contains(where: { $0.flags.contains(.overlap) }) || { if case .multiple = f.speaker { true } else { false } }() { flags.insert(.overlap) }
                if run.contains(where: { $0.flags.contains(.uncertainSpeaker) }) { flags.insert(.uncertainSpeaker) }
                if run.contains(where: { $0.flags.contains(.questionableText) }) { flags.insert(.questionableText) }
                if run.contains(where: { $0.flags.contains(.probableEchoDuplicate) }) { flags.insert(.probableEcho) }
                if run.contains(where: { correctedIDs.contains($0.id) }) { flags.insert(.corrected) }
                rows.append(TranscriptRow(id: "\(seg.id.rawValue)/\(f.id.rawValue)", kind: .speech, start: f.interval.start, end: l.interval.end,
                                          source: seg.source, assignment: f.speaker, speakerLabel: label(f.speaker, names: names),
                                          text: run.map(\.text).filter { !$0.isEmpty }.joined(separator: " "),
                                          range: WordRange(revisionID: revision.id, first: f.id, last: l.id), segmentID: seg.id, flags: flags))
                run = []
            }
            for w in seg.words {
                if let f = run.first, f.speaker != w.speaker { flush() }
                run.append(w)
            }
            flush()
        }
        for c in corrected.coverage where c.interval.duration.seconds >= minGap {
            guard let reason = gapReason(c.status) else { continue }
            rows.append(TranscriptRow(id: "gap/\(c.source.rawValue)/\(c.interval.start.nanoseconds)", kind: .gap(reason: reason),
                                      start: c.interval.start, end: c.interval.end, source: c.source, assignment: .unknown,
                                      speakerLabel: "", text: "", range: nil, segmentID: nil, flags: []))
        }
        return rows.sorted { ($0.start, $0.isGap ? 0 : 1) < ($1.start, $1.isGap ? 0 : 1) }
    }

    /// Skim mode (Details off, T25): each run of consecutive gap rows becomes one gap row (the first row's id, spanning
    /// the run, reasons joined), so many small gaps read as a single hairline. Speech rows and their ids are unchanged,
    /// so evidence jumps and context menus work in both modes. Nothing is dropped: every gap is still covered.
    public static func skim(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var out: [TranscriptRow] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            if case .gap(let reason) = row.kind, var last = out.last, case .gap(let lastReason) = last.kind {
                last.end = max(last.end, row.end)
                if !lastReason.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(reason) {
                    last.kind = .gap(reason: lastReason + "; " + reason)
                }
                out[out.count - 1] = last
            } else {
                out.append(row)
            }
        }
        return out
    }

    /// Tooltip and VoiceOver text of a gap row.
    public static func gapDescription(_ row: TranscriptRow) -> String {
        guard case .gap(let reason) = row.kind else { return "" }
        return "No transcript \(clock(row.start))–\(clock(row.end)): \(reason)"
    }

    /// Row containing the first word of an evidence reference (for "jump to evidence").
    public static func row(for evidence: TranscriptEvidence, in rows: [TranscriptRow], revision: TranscriptRevision) -> TranscriptRow? {
        guard let seg = revision.segment(evidence.segmentID), let wi = seg.words.firstIndex(where: { $0.id == evidence.firstWord }) else { return nil }
        return rows.first { r in
            guard r.segmentID == evidence.segmentID, let range = r.range,
                  let a = seg.words.firstIndex(where: { $0.id == range.first }), let b = seg.words.firstIndex(where: { $0.id == range.last }) else { return false }
            return a <= wi && wi <= b
        }
    }

    public static func clock(_ t: SessionTime) -> String {
        let s = Int(t.seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
