public import Foundation

/// Deterministic meeting-date constraints (spec 0010, rules frozen in T109 `t109-semantics.md` §1). Only phrases that
/// say *when the meeting happened* resolve; dates that are the topic ("planning for 2027", "goal for next quarter",
/// "due on Friday") never become filters. Calendar arithmetic runs in the request's time zone on calendar days, so DST
/// changes inside a range are handled; results are UTC `[start, end)` instants.
public enum DateResolver {
    public struct Match: Hashable, Sendable {
        public var range: MeetingDateRange
        /// Where the phrase is in the question (so callers can strip it from search text).
        public var phrase: String
    }

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    /// Words before a date phrase that make it a topic or deadline, not the meeting's time.
    static let topicLeads: Set<String> = ["due", "by", "until", "before", "deadline", "for", "starting", "from", "after", "since", "till"]
    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                              "fourteen": 14, "thirty": 30]

    /// The first meeting-time phrase in `question`, resolved at `now` in `timeZone`; nil if there is none.
    public static func resolve(_ question: String, now: Date, timeZone: TimeZone) -> Match? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2   // weeks start on Monday
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int, from d: Date = today) -> Date { cal.date(byAdding: .day, value: offset, to: d)! }
        let thisMonday: Date = {
            let wd = cal.component(.weekday, from: today)   // 1 = Sunday
            return day(-((wd + 5) % 7))
        }()
        /// Ranges never extend past the request (a meeting can't have happened later): end ≤ now + 1 s.
        func make(_ s: Date, _ e: Date, _ k: MeetingDateRange.Kind, _ phrase: String) -> Match {
            Match(range: MeetingDateRange(start: s, end: min(e, now.addingTimeInterval(1)), kind: k, phrase: phrase), phrase: phrase)
        }
        func lead(_ i: Int) -> String? { i > 0 ? words[i - 1] : nil }
        func isTopic(_ i: Int) -> Bool { lead(i).map(topicLeads.contains) ?? false }

        for i in words.indices {
            let w = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil
            let next2 = i + 2 < words.count ? words[i + 2] : nil
            // "in/over/during the last/past week", "the past week", "past 7 days", "last N days": rolling.
            if (w == "last" || w == "past"), let n = next {
                let preceded = i >= 1 && ["the"].contains(words[i - 1]) && i >= 2 && ["in", "over", "during", "within", "from"].contains(words[i - 2])
                let rollingWeek = n == "week" && (w == "past" || preceded)
                if rollingWeek { return make(now.addingTimeInterval(-7 * 86_400), day(1), .rolling, (preceded ? words[i - 2] + " the " : "") + "\(w) week") }
                if let count = Int(n) ?? numberWords[n], next2 == "days" || next2 == "day" {
                    return make(now.addingTimeInterval(-Double(count) * 86_400), day(1), .rolling, "\(w) \(n) \(next2!)")
                }
                if n == "week", w == "last", !isTopic(i) { return make(day(-7, from: thisMonday), thisMonday, .calendarWeek, "last week") }
                if n == "month", w == "last", !isTopic(i) {
                    let first = cal.date(from: cal.dateComponents([.year, .month], from: today))!
                    return make(cal.date(byAdding: .month, value: -1, to: first)!, first, .month, "last month")
                }
                if let wd = weekdays.firstIndex(of: n), w == "last" {
                    return make(lastWeekday(wd, today: today, cal: cal), day(1, from: lastWeekday(wd, today: today, cal: cal)), .day, "last \(n)")
                }
            }
            if w == "previous", next == "week", !isTopic(i) { return make(day(-7, from: thisMonday), thisMonday, .calendarWeek, "previous week") }
            if w == "today" || (w == "this" && (next == "morning" || next == "afternoon")) {
                if isTopic(i) { continue }
                return make(today, day(1), .day, w == "today" ? "today" : "this \(next!)")
            }
            if w == "tonight", !isTopic(i) { return make(today, day(1), .day, "tonight") }
            if w == "yesterday", !isTopic(i) { return make(day(-1), today, .day, "yesterday") }
            if w == "this", next == "week", !isTopic(i) { return make(thisMonday, day(7, from: thisMonday), .calendarWeek, "this week") }
            if w == "this", next == "month", !isTopic(i) {
                return make(cal.date(from: cal.dateComponents([.year, .month], from: today))!, day(32, from: today), .month, "this month")
            }
            // "on Monday" (most recent such day before today), "on October 28".
            if w == "on", let n = next, !isTopic(i) {
                if let wd = weekdays.firstIndex(of: n) {
                    let d = lastWeekday(wd, today: today, cal: cal)
                    return make(d, day(1, from: d), .day, "on \(n)")
                }
                if let mi = months.firstIndex(of: n), let dd = next2.flatMap(dayNumber) {
                    var c = cal.dateComponents([.year], from: today); c.month = mi + 1; c.day = dd
                    if var d = cal.date(from: c) {
                        if d > now { c.year = c.year! - 1; d = cal.date(from: c) ?? d }
                        return make(d, day(1, from: d), .day, "on \(n) \(next2!)")
                    }
                }
            }
        }
        return nil
    }

    static func dayNumber(_ s: String) -> Int? {
        let digits = s.prefix { $0.isNumber }
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }

    /// The most recent `weekday` (0 = Sunday) strictly before today.
    static func lastWeekday(_ weekday: Int, today: Date, cal: Calendar) -> Date {
        var d = cal.date(byAdding: .day, value: -1, to: today)!
        while cal.component(.weekday, from: d) - 1 != weekday { d = cal.date(byAdding: .day, value: -1, to: d)! }
        return d
    }
}
