import Foundation

/// Word error rate with an explicit, versioned normalization (published with results per plan §10).
public enum WER {
    public static let normalizationVersion = "amaranth-norm-v2"

    /// v1 normalization: lowercase; unify apostrophes; strip punctuation except intra-word apostrophes and hyphens
    /// (hyphens become spaces); collapse whitespace; drop AMI-style non-speech annotations in brackets/angles;
    /// remove fillers that references transcribe inconsistently ("um", "uh", "mm", "hmm", "mm-hmm" → removed).
    /// v2 adds: integer digit tokens (0…999 999, with optional st/nd/rd/th and %) are verbalized ("15" → "fifteen",
    /// "3rd" → "third", "20%" → "twenty percent") so formatting differences are not counted as recognition errors.
    /// Number errors still get their own report (`numberTokens`).
    public static func normalize(_ text: String) -> [String] {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        s = s.replacingOccurrences(of: #"\[[^\]]*\]|<[^>]*>|\{[^}]*\}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
        let fillers: Set<String> = ["um", "uh", "uhm", "erm", "er", "mm", "hmm", "mmm", "hm", "ah", "eh", "uh-huh", "mhm"]
        return s.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty && !fillers.contains($0) }
            .flatMap { verbalize($0) }
    }

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                       "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static let ordinalIrregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                                   "nine": "ninth", "twelve": "twelfth"]

    static func words(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        if n < 1000 { return [ones[n / 100], "hundred"] + (n % 100 == 0 ? [] : words(n % 100)) }
        return words(n / 1000) + ["thousand"] + (n % 1000 == 0 ? [] : words(n % 1000))
    }

    /// "15" → ["fifteen"]; "3rd" → ["third"]; "20%"-style tokens arrive as "20" (the % was stripped) → ["twenty"].
    static func verbalize(_ t: String) -> [String] {
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6, let n = Int(digits) else { return [t] }
        let suffix = t.dropFirst(digits.count)
        if suffix.isEmpty { return words(n) }
        guard ["st", "nd", "rd", "th"].contains(String(suffix)) else { return [t] }
        var w = words(n)
        let last = w.removeLast()
        let ord = ordinalIrregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return w + [ord]
    }

    public struct Result: Codable, Sendable, Hashable {
        public var referenceWords: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var errors: Int { substitutions + deletions + insertions }
        public var wer: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }
        /// Errors on reference tokens containing digits or number words (names/numbers report, plan §10).
        public var numberTokenErrors: Int
        public var numberTokens: Int

        public static func + (a: Result, b: Result) -> Result {
            Result(referenceWords: a.referenceWords + b.referenceWords, substitutions: a.substitutions + b.substitutions,
                   deletions: a.deletions + b.deletions, insertions: a.insertions + b.insertions,
                   numberTokenErrors: a.numberTokenErrors + b.numberTokenErrors, numberTokens: a.numberTokens + b.numberTokens)
        }
        public static let zero = Result(referenceWords: 0, substitutions: 0, deletions: 0, insertions: 0, numberTokenErrors: 0, numberTokens: 0)
    }

    static let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion"]

    static let ordinalWords: Set<String> = ["first", "second", "third", "fifth", "eighth", "ninth", "twelfth"]

    static func isNumberToken(_ t: String) -> Bool {
        if t.contains(where: \.isNumber) || numberWords.contains(t) || ordinalWords.contains(t) { return true }
        if t.hasSuffix("ieth") { return numberWords.contains(String(t.dropLast(4)) + "y") }   // twentieth
        if t.hasSuffix("th") { return numberWords.contains(String(t.dropLast(2))) }           // fourteenth, hundredth
        return false
    }

    public static func score(reference: String, hypothesis: String) -> Result {
        score(reference: normalize(reference), hypothesis: normalize(hypothesis))
    }

    /// Levenshtein alignment with backtrace; ties prefer substitution, then deletion, then insertion.
    public static func score(reference r: [String], hypothesis h: [String]) -> Result {
        let n = r.count, m = h.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
                }
            }
        }
        var i = n, j = m, sub = 0, del = 0, ins = 0, numErr = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { sub += 1; if isNumberToken(r[i - 1]) { numErr += 1 } }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                del += 1; if isNumberToken(r[i - 1]) { numErr += 1 }
                i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return Result(referenceWords: n, substitutions: sub, deletions: del, insertions: ins,
                      numberTokenErrors: numErr, numberTokens: r.filter(isNumberToken).count)
    }
}

extension WER {
    /// Index pairs (reference, hypothesis) of exactly matching words on a minimal-edit alignment.
    /// Used to validate word timestamps against reference timings.
    public static func matchedPairs(reference r: [String], hypothesis h: [String]) -> [(Int, Int)] {
        let n = r.count, m = h.count
        guard n > 0, m > 0 else { return [] }
        // Full Int32 DP matrix (~150 MB for a 36-minute meeting). Run in the harness parent, never in a measured child.
        var d = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Int32(i) }
        for j in 0...m { d[0][j] = Int32(j) }
        for i in 1...n { for j in 1...m {
            d[i][j] = min(d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
        } }
        var out: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] == h[j - 1] { out.append((i - 1, j - 1)) }
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        return out.reversed()
    }
}
