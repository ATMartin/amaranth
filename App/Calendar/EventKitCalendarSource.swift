import EventKit
import Foundation
import Presentation

/// The calendars configured on this Mac, read through EventKit (T56, docs/decisions/0006). Read-only; no network. One
/// `EKEventStore` for the app's lifetime, created lazily so nothing touches EventKit at launch.
final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _store: EKEventStore?
    private var store: EKEventStore { lock.withLock { if let s = _store { return s }; let s = EKEventStore(); _store = s; return s } }

    func authorization() -> CalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAuthorization {
        guard authorization() == .notDetermined else { return authorization() }
        _ = try? await store.requestFullAccessToEvents()
        // A store created before access was granted doesn't see the calendars; start a fresh one.
        lock.withLock { _store = nil }
        return authorization()
    }

    func calendars() -> [CalendarInfo] {
        guard authorization().canRead else { return [] }
        return store.calendars(for: .event).map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent] {
        guard authorization().canRead else { return [] }
        let store = self.store
        let calendars = calendarIDs.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        if let calendars, calendars.isEmpty { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.map).sorted { $0.start < $1.start }
    }

    static func map(_ s: EKAuthorizationStatus) -> CalendarAuthorization {
        switch s {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    /// Copies only what the spec maps: no notes, location, URL or conference link.
    static func map(_ e: EKEvent) -> CalendarEvent {
        let external = e.calendarItemExternalIdentifier ?? ""
        return CalendarEvent(identifier: external.isEmpty ? (e.eventIdentifier ?? UUID().uuidString) : external,
                             title: e.title ?? "", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                             isCancelled: e.status == .canceled, isRecurring: e.hasRecurrenceRules || e.isDetached,
                             calendarID: e.calendar?.calendarIdentifier ?? "", calendarName: e.calendar?.title,
                             attendees: (e.attendees ?? []).map(map))
    }

    static func map(_ p: EKParticipant) -> CalendarAttendee {
        let kind: CalendarAttendee.Kind = switch p.participantType {
        case .person: .person
        case .room: .room
        case .resource: .resource
        case .group: .group
        default: .unknown
        }
        let response: CalendarAttendee.Response = switch p.participantStatus {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
        let email = p.url.absoluteString.lowercased().hasPrefix("mailto:") ? String(p.url.absoluteString.dropFirst("mailto:".count)) : nil
        let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarAttendee(name: name?.isEmpty == false ? name : nil, email: email, kind: kind, response: response, isCurrentUser: p.isCurrentUser)
    }
}
