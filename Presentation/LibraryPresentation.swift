public import Foundation

/// The meeting library's day sections and row captions (Inner Circle handoff): "Today", "Yesterday", then weekdays for
/// the past week, then dates; each row reads "9:30 AM · 24 min".
public enum LibrarySections {
    public struct Section<Item>: Identifiable {
        public var title: String
        public var day: Date
        public var items: [Item]
        public var id: Date { day }
    }

    /// Groups items by the local calendar day of `date`, keeping their order (the library is newest first).
    public static func grouped<Item>(_ items: [Item], date: (Item) -> Date, now: Date = Date(), calendar: Calendar = .current) -> [Section<Item>] {
        var out: [Section<Item>] = []
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if let i = out.firstIndex(where: { $0.day == day }) { out[i].items.append(item) }
            else { out.append(Section(title: title(for: day, now: now, calendar: calendar), day: day, items: [item])) }
        }
        return out
    }

    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        if days > 1 && days < 7 { style = style.weekday(.wide) }
        else if calendar.component(.year, from: day) == calendar.component(.year, from: today) { style = style.month(.wide).day() }
        else { style = style.month(.wide).day().year() }
        return day.formatted(style)
    }

    /// "24 min", "1 h 5 min", "40 s"; never "0 min".
    public static func duration(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }
}
