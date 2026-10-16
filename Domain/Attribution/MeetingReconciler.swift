import Foundation

/// Combines an ASR revision with diarization into an attributed revision and re-applies user edits (plan §7, T07).
///
/// - Words get speakers by temporal intersection with turns on the **same source**. Abstention is first-class: no
///   evidence → `.unknown`; two clusters each covering ≥ 30 % of a word → `.multiple` + `overlap`; a near tie →
///   `uncertainSpeaker` with raw-score candidates. Acoustic grouping never invents names.
/// - Personal-mic mode proposes one local speaker for undiarized mic words (still correctable); room mode uses mic
///   diarization like any other source. A source never guarantees one human.
/// - Probable echo (system audio re-entering the mic after `echoDelay`) is flagged on runs of ≥ 3 matching mic words —
///   reversible and inspectable; words are never removed, so genuine interruptions survive.
/// - Edits authored on an earlier revision are rebased by word identity (same ASR words) or by time+text, and speakers
///   are mapped by attributed-time overlap. Ambiguous rebases are returned as `needsReview` instead of overwriting.
public struct MeetingReconciler: Reconciler {
    public var microphoneMode: MicrophoneMode
    /// Seconds by which system audio reappears in the mic (from `EchoAnalyzer`); nil = no echo detected.
    public var echoDelay: Double?
    /// The attributed revision the user's edits were authored on, used to map old speakers onto new ones.
    public var previous: TranscriptRevision?

    public init(microphoneMode: MicrophoneMode = .personal, echoDelay: Double? = nil, previous: TranscriptRevision? = nil) {
        self.microphoneMode = microphoneMode
        self.echoDelay = echoDelay
        self.previous = previous
    }

    public func combine(_ transcript: TranscriptRevision, diarization: [DiarizationResult], sourceMap: SourceMap,
                        edits: [UserEdit]) throws -> ReconciliationResult {
        // 1. Speakers in order of first appearance.
        var speakers: [Speaker] = []
        var clusterSpeaker: [String: SpeakerID] = [:]
        func key(_ run: RevisionID, _ c: ClusterID) -> String { "\(run.rawValue)/\(c.rawValue)" }
        let firstTurns = diarization.flatMap { d in d.clusters.compactMap { c in d.turns.first { $0.cluster == c }.map { (d, c, $0.interval.start) } } }
            .sorted { $0.2 < $1.2 }
        for (d, c, _) in firstTurns {
            let id = SpeakerID("spk-\(transcript.id.rawValue.prefix(8))-\(speakers.count + 1)")
            speakers.append(Speaker(id: id, label: "Speaker \(speakers.count + 1)", clusters: [ClusterRef(diarizationRunID: d.id, cluster: c)],
                                    primarySource: d.source))
            clusterSpeaker[key(d.id, c)] = id
        }
        let micDiarized = diarization.contains { $0.source == .microphone }
        var micSpeaker: SpeakerID?
        if microphoneMode == .personal, !micDiarized, transcript.allWords.contains(where: { $0.source == .microphone }) {
            let id = SpeakerID("spk-\(transcript.id.rawValue.prefix(8))-mic")
            speakers.insert(Speaker(id: id, label: "Speaker \(speakers.count + 1)", primarySource: .microphone), at: 0)
            micSpeaker = id
        }

        // 2. Word-level attribution.
        var words = transcript.allWords
        for i in words.indices {
            var w = words[i]
            w.flags.remove([.overlap, .uncertainSpeaker])
            w.candidates = []
            let dur = max(0.01, w.interval.duration.seconds)
            var scores: [SpeakerID: Double] = [:]
            var inOverlap = false
            for d in diarization where d.source == w.source {
                for t in d.turns where t.interval.overlaps(w.interval) {
                    let ov = t.interval.intersection(w.interval)?.duration.seconds ?? 0
                    if let s = clusterSpeaker[key(d.id, t.cluster)] { scores[s, default: 0] += ov / dur }
                }
                if d.overlaps.contains(where: { $0.overlaps(w.interval) }) { inOverlap = true }
                // Boundary jitter: a word just outside a turn (≤ 0.3 s) inherits the nearest turn's cluster.
                if scores.isEmpty, let near = d.turns.min(by: { gap($0.interval, w.interval) < gap($1.interval, w.interval) }),
                   gap(near.interval, w.interval) <= 0.3, let s = clusterSpeaker[key(d.id, near.cluster)] {
                    scores[s] = 0.01
                }
            }
            let ranked = scores.sorted { $0.value > $1.value }
            w.candidates = ranked.map { SpeakerCandidate(speaker: $0.key, rawScore: $0.value) }
            if ranked.isEmpty {
                w.speaker = (w.source == .microphone ? micSpeaker.map { .speaker($0) } : nil) ?? .unknown
            } else if ranked.count >= 2, ranked[1].value >= 0.3, ranked[0].value >= 0.3 {
                w.speaker = .multiple(ranked.filter { $0.value >= 0.3 }.map(\.key))
                w.flags.insert(.overlap)
            } else {
                w.speaker = .speaker(ranked[0].key)
                if ranked.count >= 2, ranked[1].value > 0, ranked[0].value / ranked[1].value < 1.5 { w.flags.insert(.uncertainSpeaker) }
            }
            if inOverlap { w.flags.insert(.overlap) }
            words[i] = w
        }

        // 3. Reversible echo flags.
        if let delay = echoDelay { flagEcho(&words, delay: delay) }

        // 4. Edits (in order). Speaker mapping from the edits' base revision onto this one.
        var review: [UserEdit] = []
        let speakerMap = previous.map { mapSpeakers(from: $0, to: words) } ?? [:]
        func resolve(_ id: SpeakerID, base: RevisionID) -> SpeakerID? {
            if speakers.contains(where: { $0.id == id }) { return id }
            return base == previous?.id ? speakerMap[id] : nil
        }
        for var e in edits.sorted(by: { $0.sequence < $1.sequence }) where e.conflict != .discarded {
            var ok = true
            switch e.operation {
            case .renameSpeaker(let id, let name):
                if let s = resolve(id, base: e.baseRevisionID), let i = speakers.firstIndex(where: { $0.id == s }) {
                    speakers[i].displayName = name
                } else { ok = false }
            case .mergeSpeakers(let from, let into):
                let target = resolve(into, base: e.baseRevisionID)
                let sources = from.map { resolve($0, base: e.baseRevisionID) }
                if let target, sources.allSatisfy({ $0 != nil }) {
                    let set = Set(sources.compactMap { $0 })
                    for i in words.indices {
                        switch words[i].speaker {
                        case .speaker(let s) where set.contains(s): words[i].speaker = .speaker(target)
                        case .multiple(let ss):
                            let mapped = Array(Set(ss.map { set.contains($0) ? target : $0 })).sorted()
                            words[i].speaker = mapped.count == 1 ? .speaker(mapped[0]) : .multiple(mapped)
                        default: break
                        }
                    }
                    for s in set where s != target {
                        if let ti = speakers.firstIndex(where: { $0.id == target }), let si = speakers.firstIndex(where: { $0.id == s }) {
                            speakers[ti].clusters += speakers[si].clusters
                        }
                    }
                    speakers.removeAll { set.contains($0.id) && $0.id != target }
                } else { ok = false }
            case .reassign(let range, let target):
                guard let idx = locate(range, in: words) else { ok = false; break }
                var assignment: SpeakerAssignment?
                switch target {
                case .existing(let id):
                    assignment = resolve(id, base: e.baseRevisionID).map { .speaker($0) }
                case .new(let id, let label):
                    if !speakers.contains(where: { $0.id == id }) { speakers.append(Speaker(id: id, label: label)) }
                    assignment = .speaker(id)
                case .unknown:
                    assignment = .unknown
                }
                guard let assignment else { ok = false; break }
                for i in idx { words[i].speaker = assignment; words[i].flags.remove(.uncertainSpeaker) }
            case .markUncertain(let range):
                if let idx = locate(range, in: words) { for i in idx { words[i].flags.insert(.uncertainSpeaker) } } else { ok = false }
            case .correctText(let range, _):
                // Original ASR text is never overwritten; the correction stays an edit applied at display/export time.
                if locate(range, in: words) == nil { ok = false }
            }
            if !ok {
                e.conflict = .needsReview
                review.append(e)
            }
        }

        // 5. Segments: split at assignment changes, pauses > 0.8 s, or 40 words.
        var segments: [TranscriptSegment] = []
        for source in SourceKind.allCases {
            var cur: [Word] = []
            func flush() {
                guard let f = cur.first, let l = cur.last else { return }
                let flags = cur.reduce(into: WordFlags()) { $0.formUnion($1.flags.intersection([.overlap, .uncertainSpeaker, .questionableText, .probableEchoDuplicate])) }
                segments.append(TranscriptSegment(id: TranscriptSegmentID("seg-\(f.id.rawValue)"), source: source,
                                                  interval: SessionInterval(unchecked: f.interval.start, max(f.interval.end, l.interval.end)),
                                                  words: cur, speaker: f.speaker, flags: flags))
                cur = []
            }
            for w in words.filter({ $0.source == source }).sorted(by: { $0.interval.start < $1.interval.start }) {
                if let last = cur.last, last.speaker != w.speaker || w.interval.start.seconds - last.interval.end.seconds > 0.8 || cur.count >= 40 { flush() }
                cur.append(w)
            }
            flush()
        }
        segments.sort { $0.interval.start < $1.interval.start }
        // Drop speakers with no remaining words (after merges) unless the user named them.
        let used = Set(segments.flatMap { $0.words.flatMap(\.speaker.speakerIDs) })
        speakers = speakers.filter { used.contains($0.id) || $0.displayName != nil }

        let revision = TranscriptRevision(meetingID: transcript.meetingID, parent: transcript.id, kind: transcript.kind, stage: .attributed,
                                          createdAt: Date(), producer: transcript.producer, segments: segments,
                                          coverage: transcript.coverage, speakers: speakers)
        try revision.validate()
        return ReconciliationResult(revision: revision, editsNeedingReview: review)
    }

    func gap(_ a: SessionInterval, _ b: SessionInterval) -> Double {
        if a.overlaps(b) { return 0 }
        return a.end <= b.start ? (b.start - a.end).seconds : (a.start - b.end).seconds
    }

    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }

    func flagEcho(_ words: inout [Word], delay: Double) {
        let sys = words.filter { $0.source == .systemOutput }
        var matched = [Bool](repeating: false, count: words.count)
        for (i, w) in words.enumerated() where w.source == .microphone {
            let t = w.interval.start.seconds - delay
            matched[i] = sys.contains { Self.norm($0.text) == Self.norm(w.text) && abs($0.interval.start.seconds - t) < 0.25 }
        }
        // Group matched mic words that follow each other within 1 s (unmatched words in between — e.g. a genuine
        // interruption spoken over the playback — do not break the group). Only groups of ≥ 3 are evidence of echo;
        // a single common word matching by chance is not.
        let hits = words.indices.filter { matched[$0] }.sorted { words[$0].interval.start < words[$1].interval.start }
        var group: [Int] = []
        func close() { if group.count >= 3 { for i in group { words[i].flags.insert(.probableEchoDuplicate) } }; group = [] }
        for i in hits {
            if let last = group.last, words[i].interval.start.seconds - words[last].interval.end.seconds > 1.0 { close() }
            group.append(i)
        }
        close()
    }

    /// Resolves a word range in this revision: by word identity (same ASR words) or by time span + text of the old words.
    func locate(_ range: WordRange, in words: [Word]) -> [Int]? {
        if let a = words.firstIndex(where: { $0.id == range.first }), let b = words.firstIndex(where: { $0.id == range.last }) {
            let src = words[a].source
            let span = SessionInterval(unchecked: min(words[a].interval.start, words[b].interval.start), max(words[a].interval.end, words[b].interval.end))
            return words.indices.filter { words[$0].source == src && words[$0].interval.start >= span.start && words[$0].interval.end <= span.end }
        }
        guard let prev = previous, prev.id == range.revisionID else { return nil }
        let pw = prev.allWords.sorted { $0.interval.start < $1.interval.start }
        guard let a = pw.firstIndex(where: { $0.id == range.first }), let b = pw.firstIndex(where: { $0.id == range.last }), a <= b else { return nil }
        let old = Array(pw[a...b])
        let margin = SessionDuration(nanoseconds: 200_000_000)
        let span = SessionInterval(unchecked: old.first!.interval.start - margin, old.last!.interval.end + margin)
        let candidates = words.indices.filter { words[$0].source == old[0].source && span.contains(words[$0].interval.start) }
            .sorted { words[$0].interval.start < words[$1].interval.start }
        // Text must match exactly (normalized) to rebase automatically; otherwise ask the user.
        guard candidates.map({ Self.norm(words[$0].text) }) == old.map({ Self.norm($0.text) }) else { return nil }
        return candidates
    }

    /// Maps each previous speaker to the new speaker with which it shares the most attributed time (≥ 60 %).
    func mapSpeakers(from prev: TranscriptRevision, to words: [Word]) -> [SpeakerID: SpeakerID] {
        var out: [SpeakerID: SpeakerID] = [:]
        for sp in prev.speakers {
            let mine = prev.allWords.filter { $0.speaker == .speaker(sp.id) }
            guard !mine.isEmpty else { continue }
            var share: [SpeakerID: Double] = [:]
            var total = 0.0
            for w in mine {
                total += w.interval.duration.seconds
                for n in words where n.source == w.source {
                    guard case .speaker(let s) = n.speaker, let ov = n.interval.intersection(w.interval) else { continue }
                    share[s, default: 0] += ov.duration.seconds
                }
            }
            if let best = share.max(by: { $0.value < $1.value }), total > 0, best.value / total >= 0.6 { out[sp.id] = best.key }
        }
        return out
    }
}
