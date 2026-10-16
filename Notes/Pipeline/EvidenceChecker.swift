import Foundation

/// Deterministic checks of a generated item against the text of the lines it cites. These never add content: they
/// can only remove an unsupported owner/deadline, mark an item uncertain, or reject it.
enum EvidenceChecker {
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func words(_ s: String) -> [String] { normalize(s).split(separator: " ").map(String.init) }

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "from",
        "is", "are", "was", "were", "be", "been", "it", "that", "this", "they", "we", "will", "would", "should", "can",
        "could", "has", "have", "had", "do", "does", "did", "as", "about", "into", "their", "its", "our", "team",
        "group", "participants", "meeting", "discussed", "agreed", "decided", "speaker", "someone", "also", "s"]

    static func stem(_ w: String) -> String {
        var w = w
        for suf in ["ing", "ed", "es", "s"] where w.count > suf.count + 3 && w.hasSuffix(suf) { w.removeLast(suf.count); break }
        return w
    }

    /// Share of the item's content words that occur (stemmed) in the passage.
    static func lexicalSupport(_ text: String, passage: String) -> Double {
        let p = Set(words(passage).map(stem))
        let c = words(text).filter { !stopwords.contains($0) && $0.count > 2 }.map(stem)
        guard !c.isEmpty else { return 1 }
        return Double(c.filter { p.contains($0) }.count) / Double(c.count)
    }

    // MARK: Numbers

    static let numberWords: [String: Int] = {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                    "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        var d: [String: Int] = [:]
        for (i, w) in ones.enumerated() { d[w] = i }
        for (w, v) in tens { d[w] = v }
        d["hundred"] = 100; d["thousand"] = 1000; d["million"] = 1_000_000
        let ord = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                   "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "fifteenth": 15, "twentieth": 20, "thirtieth": 30]
        for (w, v) in ord { d[w] = v }
        return d
    }()

    /// Numeric values mentioned (digits incl. "9,500", "7.30", "3rd"; spelled numbers summed as simple compounds).
    static func numbers(_ s: String) -> Set<Int> {
        var out = Set<Int>()
        let lower = s.lowercased()
        let digitRe = try! NSRegularExpression(pattern: #"\d[\d,]*"#)
        for m in digitRe.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let tok = String(lower[Range(m.range, in: lower)!])
            let parts = tok.split(separator: ",")
            if parts.count > 1, parts.dropFirst().allSatisfy({ $0.count == 3 }), let v = Int(parts.joined()) { out.insert(v) }
            else { for p in parts { if let v = Int(p) { out.insert(v) } } }
        }
        var acc = 0, cur = 0, inNum = false
        func end() { if inNum { out.insert(acc + cur) }; acc = 0; cur = 0; inNum = false }
        for w in words(lower) {
            guard let v = numberWords[w] else { if w != "and" || !inNum { end() }; continue }
            out.insert(v)   // each spoken number alone too ("twelve fifty" may mean 12.50, not 62)
            inNum = true
            if v == 100 { cur = max(cur, 1) * 100 }
            else if v >= 1000 { acc += max(cur, 1) * v; cur = 0 }
            else { cur += v }
        }
        end()
        // "a/one" are too common to police.
        out.remove(0); out.remove(1)
        return out
    }

    /// Numbers in the item that the passage never mentions (in digits or words).
    static func unsupportedNumbers(_ text: String, passage: String) -> Set<Int> {
        numbers(text).subtracting(numbers(passage))
    }

    // MARK: Names

    static let notNames: Set<String> = ["i", "speaker", "speakers", "unknown", "ai", "tv", "ok", "okay", "the", "we", "they",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
        "may", "june", "july", "august", "september", "october", "november", "december", "english", "euro", "euros", "dollar",
        "dollars", "lcd", "ui", "pm", "am", "q1", "q2", "q3", "q4"]

    /// Capitalised words inside sentences (likely names) that occur neither in the passage nor in the cited speakers'
    /// labels. Sentence-initial words are skipped.
    static func unsupportedNames(_ text: String, passage: String, speakers: [String] = []) -> Set<String> {
        let known = Set(words(passage + " " + speakers.joined(separator: " ")))
        var out = Set<String>()
        var sentenceStart = true
        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let token = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
            defer { sentenceStart = raw.last.map { ".!?:".contains($0) } ?? false }
            guard !sentenceStart, let first = token.first, first.isUppercase, token.count >= 3, token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { continue }
            let lower = token.lowercased()
            if notNames.contains(lower) || known.contains(lower) { continue }
            // Hyphenated or possessive forms: accept if every part is known.
            if lower.split(whereSeparator: { $0 == "-" || $0 == "'" }).allSatisfy({ known.contains(String($0)) || $0 == "s" }) { continue }
            out.insert(token)
        }
        return out
    }

    // MARK: Owner / due

    /// The owner must be a cited line's speaker label or a name that occurs in the passage.
    static func ownerSupported(_ owner: String, passage: String, speakers: [String]) -> Bool {
        let o = normalize(owner)
        guard !o.isEmpty else { return false }
        if speakers.contains(where: { normalize($0) == o }) { return true }
        let generic: Set<String> = ["team", "everyone", "all", "group", "we", "someone", "nobody", "unknown"]
        if generic.contains(o) { return false }
        return " \(normalize(passage)) ".contains(" \(o) ")
    }

    static func dueSupported(_ due: String, passage: String) -> Bool {
        let d = normalize(due)
        return !d.isEmpty && " \(normalize(passage)) ".contains(" \(d) ")
    }

    static func hasNegation(_ s: String) -> Bool {
        let neg: Set<String> = ["not", "no", "never", "don't", "doesn't", "didn't", "won't", "can't", "cannot", "shouldn't",
                                "isn't", "aren't", "wasn't", "nobody", "none", "without"]
        return words(s).contains { neg.contains($0) }
    }

    // MARK: Text addressed to an AI

    static let injectionPatterns: [NSRegularExpression] = [
        #"\b(ignore|disregard|forget|override)\b.{0,40}\b(instruction|instructions|previous|above|prompt|rules|everything)\b"#,
        #"\b(ai|assistant|chatbot|model|bot|notes?|summary|summarizer|summarizing|transcript|minutes)\b.{0,50}\b(should|must|need to|needs to|has to|will|please|make sure)\b.{0,30}\b(say|says|write|state|record|note|conclude|mark|list|report|show|claim|include)\b"#,
        #"\b(system prompt|developer message|you are now|new instructions|as an ai)\b"#,
        #"\b(dear|hey|hi|hello|attention|note to|message to)\s+(the\s+|our\s+)?(ai|assistant|summarizer|model|notes|note taker|notetaker|bot)\b"#,
        // "AI writing the summary: say …" — addressed, then an imperative after a colon or comma.
        #"\b(ai|assistant|summarizer|model|bot|notes|summary)\b[^.]{0,40}[:,]\s*(say|write|state|record|note|conclude|mark|list|report|claim|include)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func looksAddressedToAI(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return injectionPatterns.contains { $0.firstMatch(in: s, range: r) != nil }
    }
}
