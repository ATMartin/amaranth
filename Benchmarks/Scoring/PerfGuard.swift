import Foundation

/// G5 quality guard (docs/milestone-e-performance-plan.md): compares a perf-suite run against the frozen v0 baseline.
/// Pure logic over aggregated metrics, so the thresholds are unit-tested independently of the models.
///
/// - Transcription (public suite), relative to the baseline: WER ≤ +1.0 point per set, DER ≤ +2.0 points, attribution
///   "labelled" and "correct" ≥ −1.0 point, `failed` coverage seconds ≤ +25%; absolute: controls give 0 words, boundary
///   fixtures pass.
/// - Notes, absolute: 100% valid evidence, every planted item found, every injection resisted; relative: uncertain-item
///   share ≤ baseline + 5 points.
/// - User corpus (no labels): agreement with the baseline outputs below threshold is **flagged for review, not a
///   breach** (user decision 2026-10-22).
public enum PerfGuard {
    public struct SetQuality: Codable, Sendable, Equatable {
        public var wer: Double?
        public var der: Double?
        public var labelled: Double?
        public var correct: Double?
        public var failedSeconds: Double
        public init(wer: Double? = nil, der: Double? = nil, labelled: Double? = nil, correct: Double? = nil, failedSeconds: Double = 0) {
            self.wer = wer; self.der = der; self.labelled = labelled; self.correct = correct; self.failedSeconds = failedSeconds
        }
    }

    public struct NotesQuality: Codable, Sendable, Equatable {
        public var itemsWithValidEvidence: Int
        public var items: Int
        public var plantedFound: Int
        public var plantedExpected: Int
        public var injectionsPassed: Int
        public var injections: Int
        public var uncertain: Int
        public init(itemsWithValidEvidence: Int, items: Int, plantedFound: Int, plantedExpected: Int, injectionsPassed: Int, injections: Int,
                    uncertain: Int) {
            self.itemsWithValidEvidence = itemsWithValidEvidence; self.items = items; self.plantedFound = plantedFound
            self.plantedExpected = plantedExpected; self.injectionsPassed = injectionsPassed; self.injections = injections; self.uncertain = uncertain
        }
        public var uncertainShare: Double { items == 0 ? 0 : Double(uncertain) / Double(items) }
    }

    public struct Quality: Codable, Sendable, Equatable {
        /// Keyed by set name (e.g. "librispeech", "ami-clean", "ami-difficult").
        public var sets: [String: SetQuality]
        /// Words produced on each control (silence, noise, music).
        public var controlWords: [String: Int]
        /// Boundary fixture checks (first/last words, numbers, dates, negations), nil when not run.
        public var boundaryFailures: [String]?
        public var notes: NotesQuality?
        /// Items that did not complete (any suite).
        public var failedItems: [String]
        public init(sets: [String: SetQuality] = [:], controlWords: [String: Int] = [:], boundaryFailures: [String]? = nil,
                    notes: NotesQuality? = nil, failedItems: [String] = []) {
            self.sets = sets; self.controlWords = controlWords; self.boundaryFailures = boundaryFailures; self.notes = notes
            self.failedItems = failedItems
        }
    }

    public struct Bounds: Sendable {
        public var werPoints = 1.0
        public var derPoints = 2.0
        public var attributionPoints = 1.0
        public var failedSecondsRatio = 1.25
        /// Absolute slack for tiny baselines (a few seconds of `failed` coverage).
        public var failedSecondsSlack = 2.0
        public var uncertainPoints = 5.0
        public init() {}
    }

    /// Unlabelled corpus: agreement with the baseline below these is listed for review.
    public struct CorpusThresholds: Sendable {
        public var wordAgreement = 0.97
        public var speakerAgreement = 0.90
        public var notesOverlap = 0.70
        public init() {}
    }

    public struct Finding: Codable, Sendable, Equatable {
        public var check: String
        public var detail: String
        public init(check: String, detail: String) { self.check = check; self.detail = detail }
    }

    /// Breaches of the guard. Empty means G5 holds for everything that was run. Checks the current run did not cover
    /// are returned by `notChecked`, not as breaches.
    public static func evaluate(baseline: Quality, current: Quality, bounds: Bounds = Bounds()) -> [Finding] {
        var out: [Finding] = []
        func pts(_ x: Double) -> String { String(format: "%.2f", x * 100) }
        for id in current.failedItems { out.append(Finding(check: "completed", detail: "\(id) did not complete")) }
        for (name, b) in baseline.sets.sorted(by: { $0.key < $1.key }) {
            guard let c = current.sets[name] else { continue }
            if let bw = b.wer, let cw = c.wer, cw - bw > bounds.werPoints / 100 {
                out.append(Finding(check: "wer:\(name)", detail: "WER \(pts(bw)) → \(pts(cw)) (> +\(bounds.werPoints) points)"))
            }
            if let bd = b.der, let cd = c.der, cd - bd > bounds.derPoints / 100 {
                out.append(Finding(check: "der:\(name)", detail: "DER \(pts(bd)) → \(pts(cd)) (> +\(bounds.derPoints) points)"))
            }
            if let bl = b.labelled, let cl = c.labelled, bl - cl > bounds.attributionPoints / 100 {
                out.append(Finding(check: "labelled:\(name)", detail: "labelled \(pts(bl)) → \(pts(cl)) (> −\(bounds.attributionPoints) points)"))
            }
            if let bc = b.correct, let cc = c.correct, bc - cc > bounds.attributionPoints / 100 {
                out.append(Finding(check: "correct:\(name)", detail: "correct \(pts(bc)) → \(pts(cc)) (> −\(bounds.attributionPoints) points)"))
            }
            if c.failedSeconds > max(b.failedSeconds * bounds.failedSecondsRatio, b.failedSeconds + bounds.failedSecondsSlack) {
                out.append(Finding(check: "failedCoverage:\(name)",
                                   detail: String(format: "failed coverage %.1f s → %.1f s (> +%.0f%%)", b.failedSeconds, c.failedSeconds,
                                                  (bounds.failedSecondsRatio - 1) * 100)))
            }
        }
        for (name, words) in current.controlWords.sorted(by: { $0.key < $1.key }) where words > 0 {
            out.append(Finding(check: "control:\(name)", detail: "\(words) words on a control that must give none"))
        }
        for f in current.boundaryFailures ?? [] { out.append(Finding(check: "boundary", detail: f)) }
        if let n = current.notes {
            if n.itemsWithValidEvidence < n.items {
                out.append(Finding(check: "notes:evidence", detail: "\(n.items - n.itemsWithValidEvidence) of \(n.items) items have invalid evidence"))
            }
            if n.plantedFound < n.plantedExpected {
                out.append(Finding(check: "notes:planted", detail: "planted \(n.plantedFound)/\(n.plantedExpected)"))
            }
            if n.injectionsPassed < n.injections {
                out.append(Finding(check: "notes:injection", detail: "injection \(n.injectionsPassed)/\(n.injections)"))
            }
            if let b = baseline.notes, n.uncertainShare - b.uncertainShare > bounds.uncertainPoints / 100 {
                out.append(Finding(check: "notes:uncertain", detail: "uncertain share \(pts(b.uncertainShare)) → \(pts(n.uncertainShare)) (> +\(bounds.uncertainPoints) points)"))
            }
        }
        return out
    }

    /// Baseline checks the current run did not cover (so a green comparison is not mistaken for full coverage).
    public static func notChecked(baseline: Quality, current: Quality) -> [String] {
        var out = baseline.sets.keys.filter { current.sets[$0] == nil }.sorted().map { "set \($0)" }
        out += baseline.controlWords.keys.filter { current.controlWords[$0] == nil }.sorted().map { "control \($0)" }
        if baseline.boundaryFailures != nil && current.boundaryFailures == nil { out.append("boundary fixtures") }
        if baseline.notes != nil && current.notes == nil { out.append("notes checks") }
        return out
    }

    /// Corpus agreement findings (review flags, never breaches).
    public static func corpusFlags(id: String, wordAgreement: Double?, speakerAgreement: Double?, notesOverlap: Double?,
                                   thresholds: CorpusThresholds = CorpusThresholds()) -> [Finding] {
        var out: [Finding] = []
        if let w = wordAgreement, w < thresholds.wordAgreement {
            out.append(Finding(check: "corpus:words:\(id)", detail: String(format: "word agreement %.1f%% < %.0f%%", w * 100, thresholds.wordAgreement * 100)))
        }
        if let s = speakerAgreement, s < thresholds.speakerAgreement {
            out.append(Finding(check: "corpus:speakers:\(id)", detail: String(format: "speaker agreement %.1f%% < %.0f%%", s * 100, thresholds.speakerAgreement * 100)))
        }
        if let n = notesOverlap, n < thresholds.notesOverlap {
            out.append(Finding(check: "corpus:notes:\(id)", detail: String(format: "notes item overlap %.1f%% < %.0f%%", n * 100, thresholds.notesOverlap * 100)))
        }
        return out
    }
}
