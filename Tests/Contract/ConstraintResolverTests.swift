import Foundation
import Testing
import Domain

/// T113: people and follow-up constraints are resolved deterministically and never guessed.
@Suite("Constraint resolver (T113)")
struct ConstraintResolverTests {
    static let ny = TimeZone(identifier: "America/New_York")!
    static let now = ISO8601DateFormatter().date(from: "2026-11-06T16:00:00-05:00")!
    let a = MeetingID("a"), b = MeetingID("b"), c = MeetingID("c")

    func resolve(_ q: String, _ people: [QueryPlan.Person], speakers: [String: Set<MeetingID>] = [:], attendees: [String: Set<MeetingID>] = [:],
                 local: [String: Set<MeetingID>] = [:],
                 previous: ResolvedConstraints? = nil, mentioned: Set<String> = [], plan time: String? = nil) -> ResolvedConstraints {
        ConstraintResolver.resolve(question: q, plan: QueryPlan(people: people, meetingTime: time).validated(question: q), now: Self.now, timeZone: Self.ny,
                                   previous: previous, directory: NameDirectory(speakers: speakers, attendees: attendees, meetingsInScope: [a, b, c],
                                                                                localUserSpeakers: local),
                                   accountName: "Alex Martin", mentioned: { mentioned.contains($0.lowercased()) })
    }

    @Test func speakerMentionedAttendeeAndUnknownAreDistinct() {
        let q = "What did Andrew propose and what did Priya and Omar and Zed say?"
        let r = resolve(q, [.init(name: "Andrew", role: .speaker), .init(name: "Priya", role: .speaker), .init(name: "Omar", role: .speaker), .init(name: "Zed", role: .speaker)],
                        speakers: ["Andrew": [a]], attendees: ["Priya Shah": [b]], mentioned: ["omar"])
        #expect(r.people.map(\.resolution) == [.speaker, .mentionedOnly, .mentionedOnly, .unknown])
        #expect(r.people[0].speakerNames == ["Andrew"])
    }

    @Test func twoAndrewsAreAmbiguous() {
        let r = resolve("What did Andrew say?", [.init(name: "Andrew", role: .speaker)], speakers: ["Andrew": [a], "Andrew Kim": [b]])
        #expect(r.ambiguous.count == 1 && r.people[0].speakerNames == ["Andrew", "Andrew Kim"])
        let full = resolve("What did Andrew Kim say?", [.init(name: "Andrew Kim", role: .speaker)], speakers: ["Andrew": [a], "Andrew Kim": [b]])
        #expect(full.people[0].resolution == .speaker && full.people[0].speakerNames == ["Andrew Kim"])
    }

    @Test func selfNeedsAMeSpeaker() {
        let q = "What did I promise today?"
        let none = resolve(q, [.init(name: "me", role: .selfUser)], speakers: ["Speaker 2": [a]])
        #expect(none.selfUnmapped && none.selfSpeakers.isEmpty)
        let some = resolve(q, [.init(name: "me", role: .selfUser)], speakers: ["Me": [a]])
        #expect(!some.selfUnmapped && some.selfSpeakers == [a: "Me"] && some.selfUnmappedMeetings == 2, "mapped where a Me speaker exists; the rest counted")
        let all = resolve(q, [.init(name: "me", role: .selfUser)], speakers: ["Me": [a, b], "Alex Martin": [c]])
        #expect(!all.selfUnmapped && all.people[0].resolution == .selfMapped && all.selfSpeakers.count == 3)
        #expect(resolve("What did Me say", [.init(name: "Me", role: .speaker)], speakers: ["Me": [a]]).people[0].resolution != .speaker)
    }

    /// T119: the personal-mic speaker is the user unless they renamed it to someone else.
    @Test func personalMicSpeakerMapsTheUser() {
        let q = "What did I promise today?"
        let me = [QueryPlan.Person(name: "me", role: .selfUser)]
        let r = resolve(q, me, speakers: ["Alex": [a], "Sam": [b], "Speaker 2": [c]], local: ["Alex": [a], "Sam": [b]])
        #expect(r.selfSpeakers == [a: "Alex"] && r.people[0].resolution == .selfMapped && r.selfUnmappedMeetings == 2,
                "first-name rename still the user; renamed to Sam is someone else; room-mode meeting unmapped")
        let def = Speaker.$localUserNameOverride.withValue("Me") { resolve(q, me, speakers: ["Me": [a, b]], local: ["Me": [a, b]]) }
        #expect(def.selfSpeakers.count == 2)
        #expect(!ConstraintResolver.isLocalUserName("Alexandra", accountName: "Alex Martin"))
    }

    @Test func followUpDatesReplaceOrInherit() throws {
        let first = resolve("What did we decide last week about the CRM?", [])
        let w = try #require(first.dateRange)
        let inherit = resolve("And who owns it?", [], previous: first)
        #expect(inherit.dateRange == w && inherit.dateInherited)
        let replaced = resolve("Did that change this week?", [], previous: first)
        #expect(replaced.dateRange?.kind == .calendarWeek && replaced.dateRange?.start != w.start && !replaced.dateInherited)
        // The planner's time phrase is used only if the question contains it.
        #expect(resolve("what about the budget", [], plan: "yesterday").dateRange == nil)
        #expect(resolve("Anything from Yesterday?", [], plan: "Yesterday").dateRange?.kind == .day)
    }

    @Test func pronounsGroupsAndLabels() {
        let r = resolve("What did I promise we would send, and what did Speaker 2 say?", [.init(name: "I", role: .speaker), .init(name: "we", role: .mentioned),
                                                                                           .init(name: "Speaker 2", role: .speaker)])
        #expect(r.people.map(\.resolution) == [.selfUnmapped, .speaker])
        #expect(r.people[1].speakerNames == ["Speaker 2"])
        #expect(resolve("what did my team decide", []).selfUnmapped, "I/me/my always adds the user even if the planner missed it")
    }

    @Test func plannedPeopleNotInTheQuestionAreDropped() {
        let r = resolve("Who can staff the Trane project?", [.init(name: "Andrew", role: .mentioned)], speakers: ["Andrew": [a]])
        #expect(r.people.isEmpty, "a name the model made up never becomes a constraint")
    }
}
