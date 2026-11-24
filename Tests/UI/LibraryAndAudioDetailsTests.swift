import Testing
import Foundation
import Domain
@testable import Presentation

/// Inner Circle handoff: the library's day sections and captions, and Audio details in plain language.
@Suite("Library sections and audio details")
struct LibraryAndAudioDetailsTests {
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.locale = Locale(identifier: "en_US"); return c }()
    static let now = Date(timeIntervalSince1970: 1_793_000_000)   // Monday 2026-10-26 07:33 UTC

    func ago(_ days: Int, hours: Double = 0) -> Date { Self.now.addingTimeInterval(-Double(days) * 86_400 - hours * 3_600) }

    @Test func dayTitles() {
        #expect(LibrarySections.title(for: ago(0, hours: 1), now: Self.now, calendar: Self.cal) == "Today")
        #expect(LibrarySections.title(for: ago(1), now: Self.now, calendar: Self.cal) == "Yesterday")
        #expect(LibrarySections.title(for: ago(3), now: Self.now, calendar: Self.cal) == "Friday")
        #expect(LibrarySections.title(for: ago(13), now: Self.now, calendar: Self.cal) == "October 13")
        #expect(LibrarySections.title(for: ago(400), now: Self.now, calendar: Self.cal) == "September 21, 2025")
    }

    @Test func groupingKeepsOrderAndMergesADay() {
        let dates = [ago(0, hours: 1), ago(0, hours: 3), ago(1), ago(13), ago(13, hours: 1)]
        let sections = LibrarySections.grouped(Array(dates.indices), date: { dates[$0] }, now: Self.now, calendar: Self.cal)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "October 13"])
        #expect(sections.map(\.items) == [[0, 1], [2], [3, 4]])
    }

    @Test func durations() {
        #expect(LibrarySections.duration(seconds: 26) == "26 s")
        #expect(LibrarySections.duration(seconds: 24 * 60 + 18) == "24 min")
        #expect(LibrarySections.duration(seconds: 7_200) == "2 h")
        #expect(LibrarySections.duration(seconds: 3_900) == "1 h 5 min")
    }

    func event(_ source: SourceKind?, _ start: Double, _ end: Double, _ kind: CaptureEventKind = .gap) -> CaptureEvent {
        CaptureEvent(meetingID: MeetingID("m"), source: source,
                     interval: try! SessionInterval(start: .seconds(start), end: .seconds(end)),
                     kind: kind, reasonCode: "device.disconnected", recoverable: true)
    }

    @Test func gapNamesTheSourceAndOnlyClaimsTheOtherContinuedWhenItDid() {
        let both: Set<SourceKind> = [.microphone, .systemOutput]
        let one = AudioDetails.issues([event(.microphone, 1_122, 1_130)], recordedSources: both)
        #expect(one.map(\.title) == ["Microphone gap · 8 seconds"])
        #expect(one.first?.body == "No microphone from 18:42 to 18:50. System audio continued.")
        // The other source also had a gap there: no claim.
        let overlap = AudioDetails.issues([event(.microphone, 10, 20), event(.systemOutput, 15, 25)], recordedSources: both)
        #expect(overlap.allSatisfy { !$0.body.contains("continued") })
        // Only one source recorded: no claim either.
        #expect(AudioDetails.issues([event(.microphone, 10, 20)], recordedSources: [.microphone]).first?.body.contains("continued") == false)
        // Pauses and device changes are not missing audio.
        #expect(AudioDetails.issues([event(nil, 0, 5, .pause), event(.microphone, 3, 3, .deviceChange)], recordedSources: both).isEmpty)
    }

    @Test func headlines() {
        #expect(AudioDetails.headline(issues: 0, audioDeleted: false) == "Recorded without gaps.")
        #expect(AudioDetails.headline(issues: 1, audioDeleted: false) == "One moment needs a closer look.")
        #expect(AudioDetails.headline(issues: 3, audioDeleted: false) == "3 moments need a closer look.")
        #expect(AudioDetails.headline(issues: 2, audioDeleted: true) == "The audio was deleted.")
        #expect(AudioDetails.length(1) == "1 second")
        #expect(AudioDetails.length(125) == "2 min 5 s")
        #expect(AudioDetails.sourcesLabel([.microphone, .systemOutput]) == "Microphone + system audio")
    }
}
