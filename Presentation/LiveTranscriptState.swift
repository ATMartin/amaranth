public import Foundation
public import Domain

/// Live (provisional) text while recording (T14): merges worker responses per source, measures how long each word took
/// to appear after it was spoken, and builds a `.provisional` revision. Never presented as final; speakers are not
/// attributed live. T19: words from the final pipeline, decoded while recording, replace live words before their
/// `finalUntil` point (they are still unattributed and still part of a provisional revision).
public struct LiveTranscriptState: Sendable {
    public struct SourceState: Sendable {
        public var stableUntil: SessionTime = .zero
        public var stable: [Word] = []
        public var tentative: [Word] = []
        public var processedUntil: SessionTime = .zero
        /// Final-pipeline words (T19) and the point up to which they replace live words.
        public var final: [Word] = []
        public var finalUntil: SessionTime = .zero

        /// Final words, then live words after `finalUntil`.
        var shown: [Word] { final + (stable + tentative).filter { $0.interval.start >= finalUntil } }
    }

    /// One word's delay, from the end of the spoken word to its first appearance (stable or tentative), split into
    /// where the time went (T20). The parts sum to `seconds` when the request's timing is known.
    public struct LatencySample: Codable, Sendable, Hashable {
        public var source: SourceKind
        /// Session time the word ended.
        public var wordEnd: Double
        public var seconds: Double
        /// Until the end of the 2 s capture segment holding the word's end (session time; it can be read only then).
        public var unsaved: Double?
        /// From then until live text sent a request with it (saving the segment, check interval, request in flight,
        /// other source's turn).
        public var waiting: Double?
        /// Worker round trip for that request.
        public var worker: Double?
    }

    /// When a request was sent and the end times of the segments it carried (for `LatencySample`'s breakdown).
    public struct RequestTiming: Sendable {
        public var sentAt: SessionTime
        public var segmentEnds: [SessionTime]
        public init(sentAt: SessionTime, segmentEnds: [SessionTime]) { self.sentAt = sentAt; self.segmentEnds = segmentEnds.sorted() }
    }

    public private(set) var sources: [SourceKind: SourceState] = [:]
    public private(set) var samples: [LatencySample] = []
    /// Seconds from the end of a spoken word to its first appearance (stable or tentative).
    public var latencies: [Double] { samples.map(\.seconds) }
    /// Words already shown, by text → start times (a re-decoded word can shift slightly and get a new ID).
    private var seen: [String: [Double]] = [:]

    public init() {}

    public func stableUntil(_ s: SourceKind) -> SessionTime { sources[s]?.stableUntil ?? .zero }

    /// `sessionNow`: the session time when the response arrived (latency = arrival − spoken end).
    /// `measure` false (the flush at Stop) merges words without recording delay samples.
    public mutating func apply(_ r: LiveResponse, sessionNow: SessionTime, timing: RequestTiming? = nil, measure: Bool = true) {
        var s = sources[r.source] ?? SourceState()
        // Ignore stale responses (a newer pass already settled further).
        guard r.stableUntil >= s.stableUntil else { return }
        s.stable += r.stableWords.filter { w in !s.stable.contains { $0.id == w.id } }
        s.tentative = r.tentativeWords
        s.stableUntil = r.stableUntil
        s.processedUntil = max(s.processedUntil, r.processedUntil)
        sources[r.source] = s
        for w in r.stableWords + r.tentativeWords where measure {
            let key = w.text.lowercased(), start = w.interval.start.seconds
            if seen[key, default: []].contains(where: { abs($0 - start) < 0.35 }) { continue }
            seen[key, default: []].append(start)
            let end = w.interval.end.seconds, now = sessionNow.seconds
            var sample = LatencySample(source: r.source, wordEnd: end, seconds: max(0, now - end))
            if let timing, let saved = timing.segmentEnds.first(where: { $0.seconds >= end - 0.001 })?.seconds {
                let sent = min(now, max(saved, timing.sentAt.seconds))
                sample.unsaved = max(0, saved - end); sample.waiting = sent - saved; sample.worker = now - sent
            }
            samples.append(sample)
        }
    }

    /// Final-pipeline words up to `until` (T19). Words arrive window by window, in order, so they are appended.
    public mutating func applyFinal(source: SourceKind, words: [Word], until: SessionTime) {
        var s = sources[source] ?? SourceState()
        guard until >= s.finalUntil else { return }
        s.final += words.filter { w in w.interval.start >= s.finalUntil }
        s.finalUntil = until
        // Live words before the final point are no longer shown; keep only what can still be.
        s.stable.removeAll { $0.interval.start < until }
        sources[source] = s
    }

    /// All words in time order: final-pipeline words, then stable and tentative live words per source.
    public var words: [Word] {
        sources.values.flatMap(\.shown).sorted { $0.interval.start < $1.interval.start }
    }

    /// End of the newest word shown on any source (tentative words count: they are speech), for the quiet alert (T68).
    public var lastWordEnd: SessionTime? {
        // Each list is in time order, so its last word is its newest (read at 10 Hz: no full scan).
        sources.values.flatMap { [$0.final.last, $0.stable.last, $0.tentative.last].compactMap { $0?.interval.end } }.max()
    }

    public func percentile(_ p: Double) -> Double? { LiveLatencyLog.percentile(latencies, p) }

    /// Lines for display: one per source run, split at pauses over 1.5 s.
    public var lines: [(source: SourceKind, start: SessionTime, text: String, tentative: Bool)] {
        var out: [(SourceKind, SessionTime, String, Bool)] = []
        for (kind, s) in sources {
            var cur: [Word] = []
            var curTentative = false
            func flush() { if let f = cur.first { out.append((kind, f.interval.start, cur.map(\.text).joined(separator: " "), curTentative)) }; cur = [] }
            let tentativeIDs = Set(s.tentative.map(\.id))
            for w in s.shown {
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
            CoverageRegion(source: kind, interval: SessionInterval(unchecked: .zero, max(s.processedUntil, s.finalUntil)), status: .transcribed)
        }
        return TranscriptRevision(meetingID: meetingID, kind: .provisional, stage: .asr, createdAt: Date(), producer: producer,
                                  segments: segments, coverage: coverage)
    }
}

/// Live text delay for one meeting (T20), saved beside its audio as `live-latency.json`. Metrics only: word end times
/// and delays, never text, so real-recording delay can be measured after the fact.
public struct LiveLatencyLog: Codable, Sendable, Hashable {
    public struct Summary: Codable, Sendable, Hashable {
        public var samples: Int
        public var medianSeconds: Double?
        public var p95Seconds: Double?
    }
    public static let fileName = "live-latency.json"
    public var version = 1
    public var meetingID: MeetingID
    public var tickSeconds: Double
    public var requests: Int
    public var summary: [String: Summary]
    public var samples: [LiveTranscriptState.LatencySample]

    public init(meetingID: MeetingID, tickSeconds: Double, requests: Int, samples: [LiveTranscriptState.LatencySample]) {
        func r(_ v: Double?) -> Double? { v.map { ($0 * 1000).rounded() / 1000 } }
        self.meetingID = meetingID; self.tickSeconds = tickSeconds; self.requests = requests
        self.samples = samples.map { s in
            LiveTranscriptState.LatencySample(source: s.source, wordEnd: r(s.wordEnd)!, seconds: r(s.seconds)!, unsaved: r(s.unsaved),
                                              waiting: r(s.waiting), worker: r(s.worker))
        }
        var summary = ["all": Self.summarize(samples.map(\.seconds))]
        for kind in SourceKind.allCases {
            let v = samples.filter { $0.source == kind }.map(\.seconds)
            if !v.isEmpty { summary[kind.rawValue] = Self.summarize(v) }
        }
        self.summary = summary.mapValues { Summary(samples: $0.samples, medianSeconds: r($0.medianSeconds), p95Seconds: r($0.p95Seconds)) }
    }

    /// Same nearest-rank percentile as `LiveTranscriptState.percentile`.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func summarize(_ v: [Double]) -> Summary {
        Summary(samples: v.count, medianSeconds: percentile(v, 0.5), p95Seconds: percentile(v, 0.95))
    }
}
