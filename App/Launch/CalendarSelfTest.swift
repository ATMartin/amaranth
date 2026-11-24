import Foundation
import Presentation

/// `--self-test calendar-access` (T56): needs a person, like the capture trials. Launch through LaunchServices so TCC
/// attributes the prompt to Amaranth: `open -W -n Amaranth.app --args --self-test calendar-access --self-test-output f.jsonl`.
/// Asks for full access if not yet decided, then reads today's events through EventKit. Logs counts only: no event
/// titles or names leave the process. Passes once the prompt is answered either way and, with access, reading works.
enum CalendarSelfTest {
    @MainActor static func run() async -> Bool {
        let model = CalendarModel()
        let before = model.status
        SelfTest.log(["step": "status", "before": before.rawValue])
        let after = await model.request(.userAction(recording: false))
        SelfTest.log(["step": "request", "prompted": "\(before == .notDetermined)", "after": after.rawValue,
                      "presentation": "\(after.presentation)"])
        guard after != .notDetermined else { return false }
        guard after.canRead else {
            SelfTest.log(["step": "read", "skipped": "no full access (the chip offers Open Privacy Settings)"])
            return true
        }
        let calendars = model.source.calendars()
        let day = Calendar.current.startOfDay(for: Date())
        let t0 = ContinuousClock.now
        let events = model.source.events(from: day.addingTimeInterval(-86_400), to: day.addingTimeInterval(2 * 86_400), calendarIDs: nil)
        let elapsed = (ContinuousClock.now - t0).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        let attendees = events.flatMap(\.attendees)
        let mappedOK = events.allSatisfy { !$0.identifier.isEmpty && $0.end >= $0.start }
        SelfTest.log(["step": "read", "calendars": "\(calendars.count)", "events3Days": "\(events.count)", "queryMs": "\(ms)",
                      "allDay": "\(events.filter(\.isAllDay).count)", "cancelled": "\(events.filter(\.isCancelled).count)",
                      "recurring": "\(events.filter(\.isRecurring).count)", "withAttendees": "\(events.filter { !$0.attendees.isEmpty }.count)",
                      "attendees": "\(attendees.count)", "unnamed": "\(attendees.filter { $0.name == nil }.count)",
                      "rooms": "\(attendees.filter { $0.kind == .room || $0.kind == .resource }.count)", "mappedOK": "\(mappedOK)"])
        return mappedOK
    }
}
