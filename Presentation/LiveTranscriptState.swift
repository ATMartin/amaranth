public import Foundation
public import Domain

/// Live (provisional) text while recording (T14): merges worker responses per source, measures how long each word took
/// to appear after it was spoken, and builds a `.provisional` revision. Never presented as final; speakers are not
/// attributed live.
public struct LiveTranscriptState: Sendable {
    public struct SourceState: Sendable {
        public var stableUntil: SessionTime = .zero
        public var stable: [Word] = []
        public var tentative: [Word] = []
        public var processedUntil: SessionTime = .zero
    }

    public private(set) var sources: [SourceKind: SourceState] = [:]
    /// Seconds from the end of a spoken word to its first appearance (stable or tentative).
    public private(set) var latencies: [Double] = []
    /// Words already shown, by text → start times (a re-decoded word can shift slightly and get a new ID).
    private var seen: [String: [Double]] = [:]

    public init() {}

    public func stableUntil(_ s: SourceKind) -> SessionTime { sources[s]?.stableUntil ?? .zero }

    /// `sessionNow`: the session time when the response arrived (latency = arrival − spoken end).
    public mutating func apply(_ r: LiveResponse, sessionNow: SessionTime) {
        var s = sources[r.source] ?? SourceState()
        // Ignore stale responses (a newer pass already settled further).
        guard r.stableUntil >= s.stableUntil else { return }
        s.stable += r.stableWords.filter { w in !s.stable.contains { $0.id == w.id } }
        s.tentative = r.tentativeWords
        s.stableUntil = r.stableUntil
        s.processedUntil = max(s.processedUntil, r.processedUntil)
        sources[r.source] = s
        for w in r.stableWords + r.tentativeWords {
            let key = w.text.lowercased(), start = w.interval.start.seconds
            if seen[key, default: []].contains(where: { abs($0 - start) < 0.35 }) { continue }
            seen[key, default: []].append(start)
            latencies.append(max(0, (sessionNow - w.interval.end).seconds))
        }
    }

    /// All live words in time order (stable then tentative per source).
    public var words: [Word] {
        sources.values.flatMap { $0.stable + $0.tentative }.sorted { $0.interval.start < $1.interval.start }
    }

    public func percentile(_ p: Double) -> Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Lines for display: one per source run, split at pauses over 1.5 s.
    public var lines: [(source: SourceKind, start: SessionTime, text: String, tentative: Bool)] {
        var out: [(SourceKind, SessionTime, String, Bool)] = []
        for (kind, s) in sources {
            var cur: [Word] = []
            var curTentative = false
            func flush() { if let f = cur.first { out.append((kind, f.interval.start, cur.map(\.text).joined(separator: " "), curTentative)) }; cur = [] }
            let tentativeIDs = Set(s.tentative.map(\.id))
            for w in s.stable + s.tentative {
                let t = tentativeIDs.contains(w.id)
                if let l = cur.last, w.interval.start.seconds - l.interval.end.seconds > 1.5 || t != curTentative { flush() }
                curTentative = t
                cur.append(w)
            }
            flush()
        }
        return out.sorted { $0.1 < $1.1 }.map { (source: $0.0, start: $0.1, text: $0.2, tentative: $0.3) }
    }

    /// A provisional revision of what live text produced (published while recording; superseded by the final run).
    public func revision(meetingID: MeetingID, producer: ProducerInfo) -> TranscriptRevision? {
        let ws = words
        guard !ws.isEmpty else { return nil }
        var segments: [TranscriptSegment] = []
        for kind in SourceKind.allCases {
            var cur: [Word] = []
            func flush() {
                guard let f = cur.first, let l = cur.last else { return }
                segments.append(TranscriptSegment(id: TranscriptSegmentID("live-\(f.id.rawValue)"), source: kind,
                                                  interval: SessionInterval(unchecked: f.interval.start, max(f.interval.end, l.interval.end)), words: cur))
                cur = []
            }
            for w in ws where w.source == kind {
                if let l = cur.last, w.interval.start.seconds - l.interval.end.seconds > 1.5 || cur.count >= 40 { flush() }
                cur.append(w)
            }
            flush()
        }
        segments.sort { $0.interval.start < $1.interval.start }
        let coverage = sources.map { kind, s in
            CoverageRegion(source: kind, interval: SessionInterval(unchecked: .zero, s.processedUntil), status: .transcribed)
        }
        return TranscriptRevision(meetingID: meetingID, kind: .provisional, stage: .asr, createdAt: Date(), producer: producer,
                                  segments: segments, coverage: coverage)
    }
}
