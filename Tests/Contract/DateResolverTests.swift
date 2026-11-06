import Foundation
import Testing
import Domain

/// T113: meeting-date phrases resolve per the frozen T109 rules; topic dates never filter.
@Suite("Date resolver (T113)")
struct DateResolverTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    static let now = at("2026-11-06T16:00:00-05:00")   // Friday, after DST ended on Sun Nov 1

    func r(_ q: String, now: Date = now) -> MeetingDateRange? { DateResolver.resolve(q, now: now, timeZone: Self.ny)?.range }

    @Test func calendarWeekCrossesDST() throws {
        let w = try #require(r("What did Andrew propose as a new career goal last week?"))
        #expect(w.kind == .calendarWeek)
        #expect(w.start == Self.at("2026-10-26T00:00:00-04:00") && w.end == Self.at("2026-11-02T00:00:00-05:00"))
        #expect(w.contains(Self.at("2026-11-01T23:30:00-05:00")) && !w.contains(Self.at("2026-11-02T00:30:00-05:00")))
        #expect(!w.contains(Self.at("2026-10-25T22:00:00-04:00")))
        #expect(r("what happened the previous week")?.start == w.start && r("what happened the previous week")?.end == w.end)
    }

    @Test func rollingWindowsAreExactHours() throws {
        let w = try #require(r("What was said in the last week regarding who can staff the Trane project?"))
        #expect(w.kind == .rolling && w.start == Self.at("2026-10-30T17:00:00-04:00") && w.end > Self.now.addingTimeInterval(-1))
        #expect(r("anything over the last week about hiring")?.kind == .rolling)
        #expect(r("updates from the past week")?.kind == .rolling)
        #expect(r("in the past 7 days who mentioned it")?.start == Self.now.addingTimeInterval(-7 * 86_400))
        #expect(r("last three days")?.start == Self.now.addingTimeInterval(-3 * 86_400))
    }

    @Test func daysAndThisWeek() throws {
        let t = try #require(r("What follow-up actions did I promise during my calls today?"))
        #expect(t.kind == .day && t.start == Self.at("2026-11-06T00:00:00-05:00") && t.end > Self.now)
        #expect(r("what came up yesterday")?.start == Self.at("2026-11-05T00:00:00-05:00"))
        #expect(r("what came up yesterday")?.end == Self.at("2026-11-06T00:00:00-05:00"))
        #expect(r("this morning's standup")?.start == Self.at("2026-11-06T00:00:00-05:00"))
        #expect(r("decisions this week")?.start == Self.at("2026-11-02T00:00:00-05:00"))
        #expect(r("what did they say on Monday")?.start == Self.at("2026-11-02T00:00:00-05:00"))
        let sunday = try #require(r("last Sunday's call"))
        #expect(sunday.start == Self.at("2026-11-01T00:00:00-04:00") && sunday.end == Self.at("2026-11-02T00:00:00-05:00"), "a 25-hour day")
        #expect(r("on October 28 what did we agree")?.start == Self.at("2026-10-28T00:00:00-04:00"))
        #expect(r("on December 3")?.start == Self.at("2025-12-03T00:00:00-05:00"), "a future date means last year")
        #expect(r("last month")?.start == Self.at("2026-10-01T00:00:00-04:00"))
    }

    @Test func topicDatesAreNotMeetingFilters() {
        #expect(r("Did we make a final decision about strategic planning for 2027 yet?") == nil)
        #expect(r("what is Maria's goal for next quarter") == nil)
        #expect(r("which tasks are due on Friday") == nil)
        #expect(r("what needs to happen by today") == nil)
        #expect(r("what is the plan for this week's launch") == nil, "for this week = topic")
        #expect(r("who owns the budget") == nil)
    }

    @Test func requestDayEdges() throws {
        let monday = Self.at("2026-11-02T09:00:00-05:00")
        #expect(r("last week", now: monday)?.start == Self.at("2026-10-26T00:00:00-04:00"))
        #expect(r("this week", now: monday)?.start == Self.at("2026-11-02T00:00:00-05:00"))
        let sundayNoon = Self.at("2026-11-01T12:00:00-05:00")
        #expect(r("this week", now: sundayNoon)?.start == Self.at("2026-10-26T00:00:00-04:00"), "weeks start on Monday")
        #expect(r("last week", now: sundayNoon)?.start == Self.at("2026-10-19T00:00:00-04:00"))
    }
}
