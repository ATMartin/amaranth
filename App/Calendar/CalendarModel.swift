import Foundation
import Observation
import Presentation

/// Calendar access for the UI (T56). Holds the source and its last known status; never asks at launch. `request(_:)`
/// is the one place a prompt can come from, and only for a user action while not recording.
@MainActor @Observable
final class CalendarModel {
    let source: any CalendarSource
    private(set) var status: CalendarAuthorization

    init(source: any CalendarSource = EventKitCalendarSource()) {
        self.source = source
        status = source.authorization()
    }

    /// Re-reads the status (it can change in System Settings while the app runs).
    func refresh() { status = source.authorization() }

    /// Asks for access if `trigger` allows it; returns the status afterwards.
    @discardableResult
    func request(_ trigger: CalendarAccessTrigger) async -> CalendarAuthorization {
        refresh()
        guard trigger.mayRequest(status) else { return status }
        status = await source.requestAccess()
        return status
    }
}
