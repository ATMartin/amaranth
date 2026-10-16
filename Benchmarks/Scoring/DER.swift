import Foundation

/// Diarization error rate per plan §10: **no collar**, overlapping speech scored, optimal one-to-one mapping between
/// anonymous hypothesis and reference speakers. Missed speech, false alarm and confusion are reported separately.
/// Hypothesis regions labelled unknown count as missed attribution (abstention cannot game the score).
public enum DER {
    public struct Segment: Hashable, Sendable, Codable {
        public var start: Double
        public var end: Double
        public var speaker: String
        public init(start: Double, end: Double, speaker: String) {
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    public struct Result: Codable, Sendable, Hashable {
        /// Total reference speaker-time (overlap counted once per speaker), seconds.
        public var referenceSpeech: Double
        public var missed: Double
        public var falseAlarm: Double
        public var confusion: Double
        public var der: Double { referenceSpeech == 0 ? 0 : (missed + falseAlarm + confusion) / referenceSpeech }
        public var mapping: [String: String]
    }

    /// Label used by hypotheses for regions with speech but no speaker decision.
    public static let unknownLabel = "<unknown>"

    /// Parses RTTM `SPEAKER <file> <chan> <start> <dur> <NA> <NA> <spk> ...` lines.
    public static func parseRTTM(_ text: String, file: String? = nil) -> [Segment] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 8, f[0] == "SPEAKER", file == nil || String(f[1]) == file,
                  let s = Double(f[3]), let d = Double(f[4]) else { return nil }
            return Segment(start: s, end: s + d, speaker: String(f[7]))
        }
    }

    /// Parses UEM `<file> <chan> <start> <end>` scoring regions.
    public static func parseUEM(_ text: String, file: String? = nil) -> [(Double, Double)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, file == nil || String(f[0]) == file, let a = Double(f[2]), let b = Double(f[3]) else { return nil }
            return (a, b)
        }
    }

    /// Frame-based scoring at `step` seconds (10 ms default), restricted to `uem` regions when given.
    public static func score(reference: [Segment], hypothesis: [Segment], uem: [(Double, Double)]? = nil,
                             step: Double = 0.01) -> Result {
        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        let frames = Int((end / step).rounded(.up)) + 1
        let refSpk = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpk = Array(Set(hypothesis.map(\.speaker)).subtracting([unknownLabel])).sorted()
        func activity(_ segs: [Segment], _ names: [String]) -> [[Bool]] {
            var a = [[Bool]](repeating: [Bool](repeating: false, count: frames), count: names.count)
            let idx = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
            for s in segs { guard let k = idx[s.speaker] else { continue }
                let a0 = max(0, Int((s.start / step).rounded())), a1 = min(frames, Int((s.end / step).rounded()))
                if a0 < a1 { for f in a0..<a1 { a[k][f] = true } }
            }
            return a
        }
        let R = activity(reference, refSpk), H = activity(hypothesis, hypSpk)
        var unknown = [Int](repeating: 0, count: frames)
        for s in hypothesis where s.speaker == unknownLabel {
            let a0 = max(0, Int((s.start / step).rounded())), a1 = min(frames, Int((s.end / step).rounded()))
            if a0 < a1 { for f in a0..<a1 { unknown[f] += 1 } }
        }
        var scored = [Bool](repeating: uem == nil, count: frames)
        for (a, b) in uem ?? [] {
            let a0 = max(0, Int((a / step).rounded())), a1 = min(frames, Int((b / step).rounded()))
            if a0 < a1 { for f in a0..<a1 { scored[f] = true } }
        }

        // Co-occurrence matrix for optimal mapping.
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: hypSpk.count), count: refSpk.count)
        for f in 0..<frames where scored[f] {
            for i in refSpk.indices where R[i][f] { for j in hypSpk.indices where H[j][f] { overlap[i][j] += step } }
        }
        let assignment = Hungarian.maximize(overlap)
        var mapping: [String: String] = [:]
        var mappedRefForHyp = [Int?](repeating: nil, count: hypSpk.count)
        for (i, j) in assignment { mapping[hypSpk[j]] = refSpk[i]; mappedRefForHyp[j] = i }

        var refTotal = 0.0, missed = 0.0, fa = 0.0, conf = 0.0
        for f in 0..<frames where scored[f] {
            let nRef = refSpk.indices.filter { R[$0][f] }.count
            let nHyp = hypSpk.indices.filter { H[$0][f] }.count  // unknown labels are not speaker decisions
            var correct = 0
            for j in hypSpk.indices where H[j][f] { if let i = mappedRefForHyp[j], R[i][f] { correct += 1 } }
            refTotal += Double(nRef) * step
            missed += Double(max(0, nRef - nHyp)) * step
            fa += Double(max(0, nHyp - nRef)) * step
            conf += Double(min(nRef, nHyp) - correct) * step
        }
        return Result(referenceSpeech: refTotal, missed: missed, falseAlarm: fa, confusion: conf, mapping: mapping)
    }
}

/// Hungarian algorithm (Kuhn–Munkres) on a rectangular matrix; returns (row, col) pairs maximizing total weight.
enum Hungarian {
    static func maximize(_ w: [[Double]]) -> [(Int, Int)] {
        let rows = w.count, cols = w.first?.count ?? 0
        guard rows > 0, cols > 0 else { return [] }
        let n = max(rows, cols)
        let maxW = w.flatMap { $0 }.max() ?? 0
        // Convert to a square cost-minimization problem.
        var cost = [[Double]](repeating: [Double](repeating: maxW, count: n), count: n)
        for i in 0..<rows { for j in 0..<cols { cost[i][j] = maxW - w[i][j] } }
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var out: [(Int, Int)] = []
        for j in 1...n where p[j] - 1 < rows && j - 1 < cols && w[p[j] - 1][j - 1] > 0 { out.append((p[j] - 1, j - 1)) }
        return out
    }
}
