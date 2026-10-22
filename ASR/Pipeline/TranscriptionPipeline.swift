public import Foundation
public import Domain

/// T06 transcription over prepared analysis audio (plan §7).
///
/// Per source: windows that **partition all recorded audio** (VAD only chooses cut points, at the middle of silences, so
/// speech the VAD misses is still transcribed — VAD never removes audio) → Parakeet per window with acoustic context,
/// keeping only words whose midpoint falls in the window's own span (no duplicates by construction) → garble/loop check
/// and under-yield check (VAD speech with no words) with bounded re-decodes at other contexts → ordered by time. Speech
/// still without text after retries (≥ 1 s) is reported in coverage as `failed`, never as transcribed. Every
/// window edge gets 2 s of acoustic context (`WindowPolicy.default`, chosen by measurement).
///
/// Every engine call is ≤ 14.9 s, i.e. one single pass inside Parakeet's 15 s window. FluidAudio's internal chunking of
/// longer inputs (0.17.7) silently drops whole chunks at some input lengths (measured: 23.5 s → 47 words, 24.0 s → 37,
/// 24.5 s → 50), so it is never used; `ParakeetASR` refuses longer inputs. Digital silence
/// (missing audio zero-filled in the derivative) is skipped. Each window's result is checkpointed atomically;
/// a cancelled or crashed job resumes without re-running completed windows. Output is an immutable `.asr` revision whose
/// coverage distinguishes transcribed speech, recorded no-speech, paused and missing audio.
public final class TranscriptionPipeline: @unchecked Sendable {
    public struct Window: Codable, Sendable, Hashable {
        public var index: Int
        public var start: Double
        public var end: Double
        /// Acoustic context decoded on each side of the window's own span (see `EdgeKind`).
        public var leftContext: Double
        public var rightContext: Double
        /// VAD speech inside the span (session seconds), used to detect engine under-yield.
        public var speech: [[Double]] = []
    }

    public struct WindowResult: Codable, Sendable {
        public var window: Window
        public var words: [ParakeetASR.Word]   // session-time seconds
        public var questionable: Bool
        public var retried: Bool
        /// VAD speech seconds in the span left without any word nearby after retries (0 when fully covered).
        public var uncoveredSpeech: Double = 0
    }

    public static let pipelineVersion = "asr-pipeline-v8"
    /// Window policy: maximum engine input and the context decoded on each side of a window, by cut type (a real
    /// silence, a short pause in flowing speech, or a cut forced inside speech). Chosen by measurement (asr-sweep).
    public struct WindowPolicy: Sendable, Hashable, Codable {
        public var name: String
        public var maxInput: Double = ParakeetASR.maxInputSeconds
        public var silenceContext: Double
        public var pauseContext: Double
        public var forcedLeft: Double
        public var forcedRight: Double
        public var longSilence: Double = 1.0
        public var minWindow: Double = 3
        public init(name: String, silenceContext: Double, pauseContext: Double, forcedLeft: Double, forcedRight: Double,
                    longSilence: Double = 1.0, minWindow: Double = 3) {
            self.name = name; self.silenceContext = silenceContext; self.pauseContext = pauseContext
            self.forcedLeft = forcedLeft; self.forcedRight = forcedRight; self.longSilence = longSilence; self.minWindow = minWindow
        }
        /// 2 s of context on every edge, chosen by asr-sweep (evidence: Benchmarks/Results/2026-10-16-t02-run1/asr-sweep.txt).
        public static let `default` = WindowPolicy(name: "ctx2", silenceContext: 2.0, pauseContext: 2.0, forcedLeft: 2.0, forcedRight: 2.0)
    }
    public static let contextPadding = 0.3

    let asr: ParakeetASR
    /// Decoder instances used concurrently (`asr` is the first). Windows are decoded independently from a fresh decoder
    /// state, so the output does not depend on how many there are; only the wall time does (T17, processing/0002).
    let decoders: [ParakeetASR]
    let vads: [SileroVAD]
    let workDirectory: URL
    let policy: WindowPolicy
    var maxWindow: Double { policy.maxInput }
    var minWindow: Double { policy.minWindow }

    public convenience init(asr: ParakeetASR, vad: SileroVAD, workDirectory: URL, policy: WindowPolicy = .default) {
        self.init(decoders: [asr], vads: [vad], workDirectory: workDirectory, policy: policy)
    }

    public init(decoders: [ParakeetASR], vads: [SileroVAD], workDirectory: URL, policy: WindowPolicy = .default) {
        precondition(!decoders.isEmpty && !vads.isEmpty, "at least one decoder and one VAD")
        precondition(policy.maxInput <= ParakeetASR.maxInputSeconds
                     && policy.maxInput > max(policy.forcedLeft + policy.forcedRight, 2 * policy.pauseContext) + policy.minWindow,
                     "engine input must stay single-pass")
        self.asr = decoders[0]
        self.decoders = decoders
        self.vads = vads
        self.workDirectory = workDirectory
        self.policy = policy
    }

    public func run(meetingID: MeetingID, prepared: AnalysisPreparer.Output, preparedDirectory: URL,
                    cancellation: CancellationToken, progress: @Sendable (Double, JobCheckpoint) -> Void = { _, _ in }) async throws
        -> TranscriptRevision {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        // Plan all windows first (cheap relative to ASR) so progress is meaningful.
        var plans: [(SourceCoverage, AnalysisAudio, [Window])] = []
        for cov in prepared.coverage {
            try cancellation.check()
            let audio = AnalysisAudio(url: preparedDirectory.appending(path: cov.derivativeFile))
            plans.append((cov, audio, try await Perf.measure("asr.plan") { try await planWindows(cov, audio, cancellation: cancellation) }))
        }
        // Every window of every source goes to one shared queue; each decoder takes the next window when it is free.
        let plan = plans, work = plans.enumerated().flatMap { p, plan in plan.2.indices.map { (p, $0) } }
        let total = max(1, work.count)
        let queue = WorkQueue(count: work.count)
        var results = plans.map { [WindowResult?](repeating: nil, count: $0.2.count) }
        try await withoutActuallyEscaping(progress) { progress in
        try await withThrowingTaskGroup(of: [(Int, Int, WindowResult)].self) { group in
            for engine in decoders.prefix(max(1, work.count)) {
                group.addTask {
                    var out: [(Int, Int, WindowResult)] = []
                    while let n = queue.next() {
                        try cancellation.check(); try Task.checkCancellation()   // a sibling failed: stop early
                        let (p, i) = work[n]
                        out.append((p, i, try await self.transcribe(plan[p].2[i], source: plan[p].0.source, audio: plan[p].1, engine: engine)))
                        let done = queue.finished()
                        progress(Double(done) / Double(total), JobCheckpoint(completedUnits: done, totalUnits: total))
                    }
                    return out
                }
            }
            for try await batch in group { for (p, i, r) in batch { results[p][i] = r } }
        }
        }
        var segments: [TranscriptSegment] = []
        var coverage: [CoverageRegion] = []
        for ((cov, _, windows), rs) in zip(plans, results) {
            let rs = rs.map { $0! }
            Perf.measure("asr.assemble") {
                let words = Self.stitch(rs)
                segments += Self.segment(words, source: cov.source, results: rs)
                coverage += Self.coverage(cov, windows: windows, results: rs)
            }
        }
        segments.sort { $0.interval.start < $1.interval.start }
        let revision = TranscriptRevision(meetingID: meetingID, kind: .final, stage: .asr, createdAt: Date(),
                                          producer: asr.producer, segments: segments, coverage: coverage)
        try revision.validate()
        return revision
    }

    // MARK: Planning

    func planWindows(_ cov: SourceCoverage, _ audio: AnalysisAudio, cancellation: CancellationToken) async throws -> [Window] {
        let planURL = workDirectory.appending(path: "\(Self.pipelineVersion)-\(policy.name)-plan-\(cov.source.rawValue).json")
        if let d = try? Data(contentsOf: planURL), let p = try? ContractCoding.decode([Window].self, from: d) { return p }
        // VAD in 600 s chunks (5 s overlap), spread over the VAD instances; each chunk is independent.
        let chunk = 600.0, overlap = 5.0
        var chunks: [(Double, Double)] = []
        for region in cov.recorded {
            var t = region.start.seconds
            while t < region.end.seconds {
                let e = min(region.end.seconds, t + chunk)
                chunks.append((t, e))
                if e >= region.end.seconds { break }
                t = e - overlap
            }
        }
        let queue = WorkQueue(count: chunks.count), vadChunks = chunks
        var speech: [(Double, Double)] = try await withThrowingTaskGroup(of: [(Double, Double)].self) { group in
            for vad in vads.prefix(max(1, chunks.count)) {
                group.addTask {
                    var out: [(Double, Double)] = []
                    while let n = queue.next() {
                        try cancellation.check(); try Task.checkCancellation()   // a sibling failed: stop early
                        let (t, e) = vadChunks[n]
                        let samples = try Perf.measure("asr.vad.read") { try audio.read(SessionInterval(unchecked: .seconds(t), .seconds(e))) }
                        out += try await Perf.measure("asr.vad.infer") {
                            try await vad.speech(samples, padding: Self.contextPadding, maxSegment: 14).map { ($0.0 + t, $0.1 + t) }
                        }
                    }
                    return out
                }
            }
            var all: [(Double, Double)] = []
            for try await part in group { all += part }
            return all
        }
        // Merge overlapping VAD regions (chunk overlaps); silence midpoints between them are the candidate cut points.
        speech.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }
        var merged: [(Double, Double)] = []
        for sp in speech {
            if let last = merged.last, sp.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, sp.1) } else { merged.append(sp) }
        }
        // Candidate cuts at the middle of each gap between speech regions, with the gap length.
        let cuts = zip(merged, merged.dropFirst()).filter { $1.0 - $0.1 >= 0.2 }.map { (time: ($0.1 + $1.0) / 2, gap: $1.0 - $0.1) }
        let P = policy
        var windows: [Window] = []
        for region in cov.recorded {
            var cursor = region.start.seconds
            let end = region.end.seconds
            var left = P.silenceContext
            while cursor < end - 0.05 {
                if cursor + maxWindow - left - P.silenceContext >= end {
                    windows.append(Window(index: windows.count, start: cursor, end: end, leftContext: left, rightContext: P.silenceContext))
                    break
                }
                func fits(_ c: (time: Double, gap: Double), _ ctx: Double) -> Bool { c.time > cursor + minWindow && c.time <= cursor + maxWindow - left - ctx }
                // Prefer a long silence, then a short pause, else force a cut inside speech.
                if let c = cuts.last(where: { $0.gap >= P.longSilence && fits($0, P.silenceContext) }) {
                    windows.append(Window(index: windows.count, start: cursor, end: c.time, leftContext: left, rightContext: P.silenceContext))
                    cursor = c.time; left = P.silenceContext
                } else if let c = cuts.last(where: { fits($0, P.pauseContext) }) {
                    let ctx = c.gap >= P.longSilence ? P.silenceContext : P.pauseContext
                    windows.append(Window(index: windows.count, start: cursor, end: c.time, leftContext: left, rightContext: ctx))
                    cursor = c.time; left = ctx
                } else {
                    let forced = min(end, cursor + maxWindow - left - P.forcedRight)
                    windows.append(Window(index: windows.count, start: cursor, end: forced, leftContext: left, rightContext: P.forcedRight))
                    cursor = forced; left = P.forcedLeft
                }
            }
        }
        for i in windows.indices {
            let (a, b) = (windows[i].start, windows[i].end)
            windows[i].speech = merged.compactMap { sp in sp.0 < b && sp.1 > a ? [max(a, sp.0), min(b, sp.1)] : nil }
        }
        try ContractCoding.encode(windows).write(to: planURL, options: .atomic)
        return windows
    }

    // MARK: Per-window ASR with checkpoint

    func transcribe(_ w: Window, source: SourceKind, audio: AnalysisAudio, engine: ParakeetASR? = nil) async throws -> WindowResult {
        let asr = engine ?? asr
        let url = workDirectory.appending(path: "\(Self.pipelineVersion)-\(policy.name)-\(source.rawValue)-w\(w.index).json")
        if let d = try? Perf.measure("asr.checkpoint.read", { try Data(contentsOf: url) }),
           let r = try? ContractCoding.decode(WindowResult.self, from: d) { Perf.count("asr.windows.resumed"); return r }
        Perf.count("asr.windows")
        // Digital silence (zero-filled missing audio) cannot contain speech: skip it.
        let own = try Perf.measure("asr.window.read") { try audio.read(SessionInterval(unchecked: .seconds(w.start), .seconds(w.end))) }
        let peak = own.reduce(Float(0)) { max($0, abs($1)) }
        if peak < 1e-4 {
            Perf.count("asr.windows.silent")
            let r = WindowResult(window: w, words: [], questionable: false, retried: false)
            try Perf.measure("asr.checkpoint.write") { try ContractCoding.encode(r).write(to: url, options: .atomic) }
            return r
        }
        func run(left: Double, right: Double) async throws -> [ParakeetASR.Word] {
            let a = max(0, w.start - left)
            let samples = try Perf.measure("asr.window.read") { try audio.read(SessionInterval(unchecked: .seconds(a), .seconds(w.end + right))) }
            Perf.add("asr.decode.audioSeconds", seconds: Double(samples.count) / Double(AnalysisAudio.sampleRate), count: 0)
            return try await Perf.measure("asr.decode") { try await asr.transcribe(samples) }.compactMap {
                let word = ParakeetASR.Word(text: $0.text, start: $0.start + a, end: $0.end + a, tokenConfidence: $0.tokenConfidence)
                let mid = (word.start + word.end) / 2
                return mid >= w.start && mid < w.end ? word : nil   // each word belongs to exactly one window
            }
        }
        // Parakeet (greedy TDT) occasionally skips a whole stretch of clear speech, content-dependently (measured: an
        // 11 s span returned only the 3 words of its right context). Detect it against VAD speech and re-decode with
        // other contexts inside the same single-pass budget; keep the best-covered non-garbled result. Never invents.
        let first = ContinuousClock.now
        var words = try await run(left: w.leftContext, right: w.rightContext)
        Perf.add("asr.decode.first", seconds: Perf.seconds(since: first))
        var questionable = GarbleDetector.isQuestionable(words.map(\.text))
        var uncovered = Self.uncoveredSpeech(w.speech, words)
        var retried = false
        if questionable || uncovered >= Self.underYieldSeconds {
            let retryStart = ContinuousClock.now
            defer { Perf.add("asr.decode.retries", seconds: Perf.seconds(since: retryStart)) }
            Perf.count(questionable ? "asr.windows.retried.garbled" : "asr.windows.retried.underYield")
            let budget = maxWindow - (w.end - w.start)
            let p = policy
            var variants: [(Double, Double)] = [(min(0.3, budget / 2), min(0.3, budget / 2)), (0, 0),
                                                (min(p.forcedLeft, budget * 0.66), min(p.forcedRight, budget * 0.34)),
                                                (max(0, budget - 0.3), min(0.3, budget)), (min(0.3, budget), max(0, budget - 0.3))]
            variants = variants.filter { $0 != (w.leftContext, w.rightContext) && $0.0 + $0.1 <= budget + 0.001 }
            var seen = Set<String>()
            for (l, r) in variants where seen.insert(String(format: "%.2f/%.2f", l, r)).inserted {
                let alt = try await run(left: l, right: r)
                retried = true
                let altQ = GarbleDetector.isQuestionable(alt.map(\.text))
                let altU = Self.uncoveredSpeech(w.speech, alt)
                // An empty or garbled re-decode is never accepted as a fix.
                if !alt.isEmpty, !altQ, questionable || altU < uncovered - 0.25 {
                    words = alt; questionable = false; uncovered = altU
                }
                if !questionable && uncovered < Self.underYieldSeconds { break }
            }
        }
        let r = WindowResult(window: w, words: words, questionable: questionable, retried: retried, uncoveredSpeech: uncovered)
        try Perf.measure("asr.checkpoint.write") { try ContractCoding.encode(r).write(to: url, options: .atomic) }
        return r
    }

    /// A window is re-decoded when at least this much VAD speech has no word nearby.
    public static let underYieldSeconds = 2.0

    /// Seconds of VAD speech farther than 0.6 s from every word (words are sorted by time).
    static func uncoveredSpeech(_ speech: [[Double]], _ words: [ParakeetASR.Word]) -> Double {
        uncoveredIntervals(speech, words).reduce(0) { $0 + $1.1 - $1.0 }
    }

    /// Stretches of VAD speech farther than 0.6 s from every word.
    static func uncoveredIntervals(_ speech: [[Double]], _ words: [ParakeetASR.Word]) -> [(Double, Double)] {
        let covered = words.map { ($0.start - 0.6, $0.end + 0.6) }.sorted { $0.0 < $1.0 }
        var out: [(Double, Double)] = []
        for sp in speech where sp.count == 2 {
            var t = sp[0]
            for c in covered where c.1 > t && c.0 < sp[1] {
                if c.0 > t { out.append((t, c.0)) }
                t = max(t, c.1)
                if t >= sp[1] { break }
            }
            if t < sp[1] { out.append((t, sp[1])) }
        }
        return out
    }

    /// Uncovered speech at least this long is reported in coverage as `failed` (speech detected, no text).
    public static let reportedGapSeconds = 1.0

    // MARK: Stitching and segmentation

    /// Keeps each word from the window where it is farthest from a window edge; drops near-duplicates in overlaps.
    static func stitch(_ results: [WindowResult]) -> [(ParakeetASR.Word, WindowResult)] {
        var all: [(ParakeetASR.Word, WindowResult, Double)] = []
        for r in results {
            for w in r.words {
                let mid = (w.start + w.end) / 2
                all.append((w, r, min(mid - r.window.start, r.window.end - mid)))
            }
        }
        all.sort { $0.0.start < $1.0.start }
        var kept: [(ParakeetASR.Word, WindowResult, Double)] = []
        for item in all {
            if let last = kept.last, last.1.window.index != item.1.window.index {
                let overlap = min(last.0.end, item.0.end) - max(last.0.start, item.0.start)
                let shorter = min(last.0.end - last.0.start, item.0.end - item.0.start)
                let same = last.0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                    == item.0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if overlap > 0.5 * max(shorter, 0.05) || (same && abs(last.0.start - item.0.start) < 0.3) {
                    if item.2 > last.2 { kept[kept.count - 1] = item }
                    continue
                }
            }
            kept.append(item)
        }
        return kept.map { ($0.0, $0.1) }
    }

    static func segment(_ words: [(ParakeetASR.Word, WindowResult)], source: SourceKind, results: [WindowResult]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let iv = SessionInterval(unchecked: f.interval.start, l.interval.end)
            out.append(TranscriptSegment(source: source, interval: iv, words: cur,
                                         flags: cur.contains { $0.flags.contains(.questionableText) } ? [.questionableText] : []))
            cur = []
        }
        for (w, r) in words {
            let start = SessionTime.seconds(w.start), end = SessionTime.seconds(max(w.end, w.start))
            if let last = cur.last, start.seconds - last.interval.end.seconds > 0.8 || cur.count >= 40 { flush() }
            var flags: WordFlags = []
            if r.questionable { flags.insert(.questionableText) }
            if r.retried { flags.insert(.retried) }
            cur.append(Word(text: w.text, interval: SessionInterval(unchecked: start, end), source: source,
                            quality: ASRQuality(engine: "parakeet-tdt-0.6b-v3", values: ["tokenConfidenceMean": w.tokenConfidence]),
                            flags: flags))
        }
        flush()
        return out
    }

    /// Prepared coverage refined: inside recorded audio, ASR windows are `transcribed`, the rest `noSpeech`.
    static func coverage(_ cov: SourceCoverage, windows: [Window], results: [WindowResult]) -> [CoverageRegion] {
        // Speech the engine left without text (after retries) is never presented as transcribed.
        var failed: [(Double, Double)] = []
        for r in results {
            failed += uncoveredIntervals(r.window.speech, r.words).filter { $0.1 - $0.0 >= reportedGapSeconds }
        }
        failed.sort { $0.0 < $1.0 }
        var out: [CoverageRegion] = []
        func emit(_ a: SessionTime, _ b: SessionTime, _ status: CoverageRegion.Status) {
            guard b > a else { return }
            guard status == .transcribed else { out.append(CoverageRegion(source: cov.source, interval: SessionInterval(unchecked: a, b), status: status)); return }
            var t = a
            for f in failed where f.1 > a.seconds && f.0 < b.seconds {
                let fa = max(t, .seconds(f.0)), fb = min(b, .seconds(f.1))
                if fa > t { out.append(CoverageRegion(source: cov.source, interval: SessionInterval(unchecked: t, fa), status: .transcribed)) }
                if fb > fa { out.append(CoverageRegion(source: cov.source, interval: SessionInterval(unchecked: fa, fb), status: .failed)) }
                t = max(t, fb)
            }
            if b > t { out.append(CoverageRegion(source: cov.source, interval: SessionInterval(unchecked: t, b), status: .transcribed)) }
        }
        for r in cov.regions {
            guard r.status == .transcribed else { out.append(r); continue }
            var cursor = r.interval.start
            for w in windows where w.end > r.interval.start.seconds && w.start < r.interval.end.seconds {
                let a = max(r.interval.start, .seconds(w.start)), b = min(r.interval.end, .seconds(w.end))
                if a > cursor { emit(cursor, a, .noSpeech) }
                emit(max(a, cursor), b, .transcribed)
                cursor = max(cursor, b)
            }
            emit(cursor, r.interval.end, .noSpeech)
        }
        return out
    }
}

/// Flags degenerate ASR output (FluidAudio#760-style corruption, repetition loops) for a bounded retry.
public enum GarbleDetector {
    public static func isQuestionable(_ words: [String]) -> Bool {
        let tokens = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard tokens.count >= 4 else { return false }
        // Mostly-uppercase output (garbled decoding), ignoring short acronyms.
        let long = tokens.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
        if long.count >= 4, Double(long.filter { $0 == $0.uppercased() }.count) / Double(long.count) > 0.6 { return true }
        // Repetition loop: one token ≥ 5 times in a row, or a 3-gram repeated ≥ 4 times consecutively.
        var run = 1
        for i in 1..<tokens.count {
            run = tokens[i].lowercased() == tokens[i - 1].lowercased() ? run + 1 : 1
            if run >= 5 { return true }
        }
        if tokens.count >= 12 {
            for i in 0...(tokens.count - 12) {
                let g = tokens[i..<i + 3].map { $0.lowercased() }
                if (1...3).allSatisfy({ k in tokens[(i + 3 * k)..<(i + 3 * k + 3)].map { $0.lowercased() } == g }) { return true }
            }
        }
        return false
    }
}

/// Hands out work item indices to concurrent workers and counts completions.
final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var nextIndex = 0, done = 0
    init(count: Int) { self.count = count }
    func next() -> Int? { lock.withLock { guard nextIndex < count else { return nil }; defer { nextIndex += 1 }; return nextIndex } }
    func finished() -> Int { lock.withLock { done += 1; return done } }
}
