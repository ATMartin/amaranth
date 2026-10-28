import SwiftUI
import AppKit
import Domain
import Presentation

/// The header's calendar chip (T57, replaces the T50 placeholder): link, unlink, update or use the event's title. The
/// first click asks for calendar access if it was never decided (never while recording). Every change is the user's.
struct CalendarLinkChip: View {
    let meeting: Meeting
    var compact = false
    var iconOnly = false
    @Environment(CalendarModel.self) private var calendar
    @Environment(LibraryModel.self) private var library
    @Environment(RecorderModel.self) private var recorder
    @State private var showing = false
    @State private var choosing = false
    @State private var hovering = false
    @State private var live: CalendarLinking.LiveStatus = .unknown
    @State private var also: [Meeting] = []
    @State private var events: [CalendarEvent] = []

    var chip: CalendarChip { CalendarChip.state(linked: meeting.linkedEvent, access: calendar.status, live: live) }

    var body: some View {
        Button { Task { await open() } } label: {
            HeaderChip(symbol: chip.symbol, text: iconOnly ? "" : chip.label(compact: compact), style: chip == .managed ? .inert : .action, hovering: hovering,
                       attention: chip.needsAttention)
        }
        .buttonStyle(.plain)
        .disabled(chip == .managed)
        .onHover { hovering = $0 }
        .help(chip.help)
        .accessibilityLabel(chip.label(compact: false))
        .accessibilityHint(meeting.linkedEvent == nil ? "Link a calendar event" : "Shows the linked event, Update and Unlink")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        .task(id: TaskKey(event: meeting.linkedEvent, status: calendar.status)) { refreshLive() }
        .onChange(of: showing) { _, open in if !open { choosing = false } }
    }

    struct TaskKey: Equatable { let event: LinkedEvent?; let status: CalendarAuthorization }

    @ViewBuilder var popover: some View {
        if let linked = meeting.linkedEvent, !choosing {
            LinkedEventDetails(event: linked, status: calendar.status.canRead ? live : .unknown, also: also.map(\.title),
                               offersEventTitle: CalendarLinking.offersEventTitle(meeting), access: calendar.status,
                               allow: { Task { await calendar.request(.userAction(recording: recorder.inSession)); refreshLive() } },
                               update: { if case .changed(let e) = live { library.link(meeting.id, to: e); showing = false } },
                               useTitle: { library.rename(meeting.id, to: linked.title); showing = false },
                               change: { loadEvents(); choosing = true },
                               unlink: { library.unlink(meeting.id); showing = false })
        } else if calendar.status.canRead {
            CalendarEventPicker(events: events, recordedAt: meeting.createdAt) { e in library.link(meeting.id, to: e); showing = false }
        } else if calendar.status == .notDetermined {
            CalendarAccessMessage(kind: .afterRecording)
        } else {
            CalendarAccessMessage(kind: calendar.status == .restricted ? .managed : .off)
        }
    }

    func open() async {
        calendar.refresh()
        if calendar.status == .notDetermined, meeting.linkedEvent == nil {
            await calendar.request(.userAction(recording: recorder.inSession))
        }
        loadEvents()
        refreshLive()
        showing = true
    }

    func loadEvents() {
        guard calendar.status.canRead else { events = []; return }
        let day = CalendarLinking.day(of: meeting.createdAt)
        events = CalendarLinking.pickerEvents(calendar.source.events(from: day.start, to: day.end, calendarIDs: nil), recordedAt: meeting.createdAt)
    }

    func refreshLive() {
        guard let linked = meeting.linkedEvent else { live = .unknown; also = []; return }
        let window = CalendarLinking.lookupWindow(linked)
        live = CalendarLinking.liveStatus(of: linked, in: calendar.source.events(from: window.start, to: window.end, calendarIDs: nil),
                                          access: calendar.status)
        also = CalendarLinking.alsoLinked(meeting, among: (try? library.store?.meetings(linkedTo: linked.identifier)) ?? [])
    }
}

/// The picker (T57): events of the recording's day, nearest to its start first, with a search field.
struct CalendarEventPicker: View {
    let events: [CalendarEvent]
    let recordedAt: Date
    let link: (CalendarEvent) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = CalendarLinking.filter(events, query: query)
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            Text("Link to an event on \(recordedAt.formatted(date: .abbreviated, time: .omitted))").appFont(.headline)
            TextField("Search events", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
            if shown.isEmpty {
                Text(events.isEmpty ? "No events in your calendars that day." : "No events match “\(query)”.")
                    .appFont(.callout).italic().foregroundStyle(Color.brandSecondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { e in CalendarEventRow(event: e) { link(e) } }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { searchFocused = true }
    }
}

struct CalendarEventRow: View {
    let event: CalendarEvent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: AppStyle.half) {
                    Text(event.title.isEmpty ? "Untitled event" : event.title).appFont(.body).lineLimit(1)
                    if event.declinedByMe { Text("Declined").appFont(.caption).foregroundStyle(Color.brandSecondary) }
                }
                Text([CalendarLinking.timeRange(start: event.start, end: event.end, allDay: event.isAllDay), event.calendarName]
                        .compactMap { $0 }.joined(separator: " · "))
                    .appFont(.caption).foregroundStyle(Color.brandSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppStyle.half + 2).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(event.title), \(CalendarLinking.timeRange(start: event.start, end: event.end, allDay: event.isAllDay))")
        .accessibilityHint("Link this recording to the event")
    }
}

/// The linked event (T57): what's stored, how it compares with the calendar now, and the actions.
struct LinkedEventDetails: View {
    let event: LinkedEvent
    let status: CalendarLinking.LiveStatus
    let also: [String]
    let offersEventTitle: Bool
    var access: CalendarAuthorization = .fullAccess
    var allow: () -> Void = {}
    let update: () -> Void
    let useTitle: () -> Void
    let change: () -> Void
    let unlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "Untitled event" : event.title).appFont(.headline)
                Text([event.start.formatted(date: .abbreviated, time: .omitted) + " " + CalendarLinking.timeRange(start: event.start, end: event.end),
                      event.calendarName].compactMap { $0 }.joined(separator: " · "))
                    .appFont(.caption).foregroundStyle(Color.brandSecondary)
            }
            switch status {
            case .changed(let now):
                HStack(alignment: .firstTextBaseline) {
                    Label("Event changed since linking", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Color.statusAttention)
                    Spacer()
                    Button("Update", action: update).help("Copy the event's current title and time")
                }
                .appFont(.callout)
                Text("Now: “\(now.title.isEmpty ? "Untitled event" : now.title)”, \(now.start.formatted(date: .abbreviated, time: .omitted)) \(CalendarLinking.timeRange(start: now.start, end: now.end))")
                    .appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            case .missing:
                Label("No longer in your calendar. The copy linked here is kept.", systemImage: "calendar.badge.exclamationmark")
                    .appFont(.callout).foregroundStyle(Color.statusAttention).fixedSize(horizontal: false, vertical: true)
            case .current, .unknown:
                if access == .notDetermined {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Allow calendar access to check this event for changes or link another.").appFont(.caption).foregroundStyle(Color.brandSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Allow Access…", action: allow)
                    }
                } else if !access.canRead {
                    Text("Calendar access is off, so Amaranth can't check this event for changes.").appFont(.caption).foregroundStyle(Color.brandSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !also.isEmpty {
                Label("Also linked to: " + also.joined(separator: ", "), systemImage: "link").appFont(.caption).foregroundStyle(Color.brandSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Unlink", action: unlink).help("Remove the link. People added from the event stay; remove any you don't want in the people editor.")
                if access.canRead { Button("Change Event…", action: change) }
                Spacer()
                if offersEventTitle {
                    Button("Use Event Title", action: useTitle).help("Rename this meeting to “\(event.title)”")
                }
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }
}

/// Why the picker isn't available (T57): access off, managed by an administrator, or undecided while recording.
struct CalendarAccessMessage: View {
    enum Kind { case off, managed, afterRecording }
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            Text(kind == .afterRecording ? "Link after the recording" : "Calendar access is off").appFont(.headline)
            Text(text).appFont(.callout).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            if kind == .off {
                HStack {
                    Spacer()
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(CalendarAuthorization.privacySettingsURL) }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    var text: String {
        switch kind {
        case .off: "Amaranth reads your calendars to name recordings and list who was invited. Nothing leaves this Mac. Turn on Amaranth under System Settings → Privacy & Security → Calendars, then click the chip again."
        case .managed: "Your administrator controls calendar access on this Mac."
        case .afterRecording: "Amaranth asks for calendar access only when you're not recording, so the permission prompt can't interrupt it. Click the chip again after you stop."
        }
    }
}
