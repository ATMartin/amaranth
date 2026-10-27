public import Foundation

/// Calendar access as the app sees it (T56, docs/decisions/0006 "Permission flow"). Mirrors EventKit's
/// `EKAuthorizationStatus` so the rules can be tested without EventKit.
public enum CalendarAuthorization: String, Sendable, Equatable, CaseIterable {
    case notDetermined, fullAccess, denied, restricted, writeOnly

    /// Only full access can read events; write-only is treated like denied.
    public var canRead: Bool { self == .fullAccess }

    /// What the header chip and Settings show for this state.
    public enum Presentation: Sendable, Equatable {
        /// Asks on click (the only time a prompt may appear).
        case askOnClick
        /// The picker.
        case ready
        /// "Calendar access is off" with an Open Privacy Settings button. No retry: macOS won't prompt twice.
        case off
        /// Disabled: the administrator controls calendar access.
        case managed
    }

    public var presentation: Presentation {
        switch self {
        case .notDetermined: .askOnClick
        case .fullAccess: .ready
        case .denied, .writeOnly: .off
        case .restricted: .managed
        }
    }

    /// System Settings → Privacy & Security → Calendars.
    public static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
}

/// What may trigger the system's calendar prompt. Only a user action does, and never while recording: a system prompt
/// on top of Record can stall capture start (Milestone A).
public enum CalendarAccessTrigger: Sendable, Equatable {
    case launch
    case recordingStarted
    /// First click on the header chip, or turning on a calendar setting.
    case userAction(recording: Bool)

    public func mayRequest(_ status: CalendarAuthorization) -> Bool {
        guard status == .notDetermined else { return false }
        if case .userAction(let recording) = self { return !recording }
        return false
    }
}

/// One attendee as EventKit reports it. `name` is the display name (nil when the invitation has none).
public struct CalendarAttendee: Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case person, room, resource, group, unknown }
    public enum Response: Sendable, Hashable { case accepted, declined, tentative, pending, unknown }
    public var name: String?
    public var email: String?
    public var kind: Kind
    public var response: Response
    public var isCurrentUser: Bool
    public init(name: String?, email: String? = nil, kind: Kind = .person, response: Response = .unknown, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.kind = kind
        self.response = response
        self.isCurrentUser = isCurrentUser
    }
}

/// One occurrence of a calendar event, copied out of EventKit. Notes, location, URLs and conference links are never
/// read (spec "Privacy").
public struct CalendarEvent: Hashable, Sendable, Identifiable {
    /// `calendarItemExternalIdentifier`, else `eventIdentifier`. Recurring occurrences share it; `start` tells them apart.
    public var identifier: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var isRecurring: Bool
    public var calendarID: String
    public var calendarName: String?
    public var attendees: [CalendarAttendee]

    /// Unique per occurrence.
    public var id: String { "\(identifier)@\(start.timeIntervalSinceReferenceDate)" }

    /// The current user declined the invitation.
    public var declinedByMe: Bool { attendees.contains { $0.isCurrentUser && $0.response == .declined } }

    public init(identifier: String, title: String, start: Date, end: Date, isAllDay: Bool = false, isCancelled: Bool = false,
                isRecurring: Bool = false, calendarID: String = "cal", calendarName: String? = nil, attendees: [CalendarAttendee] = []) {
        self.identifier = identifier
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.isRecurring = isRecurring
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.attendees = attendees
    }
}

/// A calendar configured on this Mac (for Settings → Calendar's reminder list).
public struct CalendarInfo: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// The calendars macOS already has (spec "Testing approach"): EventKit in the app, `FakeCalendarSource` in tests and
/// ui-render. Read-only: there is nothing here that writes to a calendar.
public protocol CalendarSource: AnyObject, Sendable {
    func authorization() -> CalendarAuthorization
    /// Shows the system prompt when the status is not determined; returns the new status.
    func requestAccess() async -> CalendarAuthorization
    func calendars() -> [CalendarInfo]
    /// Occurrences overlapping `start..<end`, from `calendarIDs` (nil: every calendar). Empty without full access.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent]
}

/// In-memory calendar for tests and ui-render. `requests` counts prompts, so tests can prove none happens unasked.
public final class FakeCalendarSource: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var status: CalendarAuthorization
    /// What the "prompt" answers when asked.
    private let answer: CalendarAuthorization
    private var stored: [CalendarEvent]
    private var calendarList: [CalendarInfo]
    private var requestCount = 0

    public init(status: CalendarAuthorization = .fullAccess, answer: CalendarAuthorization = .fullAccess, events: [CalendarEvent] = [],
                calendars: [CalendarInfo] = [CalendarInfo(id: "cal", title: "Work")]) {
        self.status = status
        self.answer = answer
        self.stored = events
        self.calendarList = calendars
    }

    public var requests: Int { lock.withLock { requestCount } }
    public func setEvents(_ events: [CalendarEvent]) { lock.withLock { stored = events } }
    public func setStatus(_ s: CalendarAuthorization) { lock.withLock { status = s } }

    public func authorization() -> CalendarAuthorization { lock.withLock { status } }

    public func requestAccess() async -> CalendarAuthorization {
        lock.withLock {
            requestCount += 1
            if status == .notDetermined { status = answer }
            return status
        }
    }

    public func calendars() -> [CalendarInfo] { lock.withLock { status.canRead ? calendarList : [] } }

    public func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent] {
        lock.withLock {
            guard status.canRead else { return [] }
            return stored.filter { $0.start < end && $0.end > start && (calendarIDs?.contains($0.calendarID) ?? true) }
                .sorted { $0.start < $1.start }
        }
    }
}
