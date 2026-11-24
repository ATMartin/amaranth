import SwiftUI
import AppKit
import Presentation

/// Settings → Calendar (T59; T61 adds the reminder and data controls). Turning a calendar feature on is a user action,
/// so it may show the system prompt (never while recording).
struct CalendarSettingsView: View {
    var calendar: CalendarModel
    var recorder: RecorderModel
    var reminders: ReminderController?
    var library: LibraryModel?
    @AppStorage(CalendarSettings.suggestKey) private var suggest = CalendarSettings.suggestDefault
    @AppStorage(CalendarSettings.reminderKey) private var reminder = CalendarSettings.reminderDefault
    @AppStorage(CalendarSettings.keepEmailsKey) private var keepEmails = CalendarSettings.keepEmailsDefault
    @State private var chosen: Set<String> = CalendarSettings.reminderCalendars()
    @State private var confirmingRemove = false
    @State private var removedMessage: String?

    var body: some View {
        Form {
            Section {
                CalendarAccessRow(calendar: calendar, recorder: recorder)
                Toggle("Suggest calendar events when recording", isOn: $suggest)
                    .onChange(of: suggest) { _, on in if on { Task { await calendar.request(.userAction(recording: recorder.inSession)) } } }
                Text("When you press Record during (or up to 10 minutes before) an event, the recording bar asks whether this is that meeting. Nothing is linked or renamed unless you choose Link, and the event's title is used only if you didn't type one.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            Section("Reminder") {
                Toggle("Remind me a minute before meetings", isOn: $reminder)
                    .onChange(of: reminder) { _, on in
                        if on { Task { await reminders?.enable(); chosen = CalendarSettings.reminderCalendars() } } else { reminders?.sync() }
                    }
                Text("A notification about a minute before each event in the calendars below. Clicking it opens Amaranth and offers that event when you press Record. Amaranth never starts recording on its own.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
                if reminders?.notificationsDenied == true {
                    Text("Notifications for Amaranth are off in System Settings → Notifications.").font(.caption).foregroundStyle(Color.statusAttention)
                }
                if reminder, calendar.status.canRead {
                    ForEach(calendar.source.calendars()) { c in
                        Toggle(c.title, isOn: Binding(get: { chosen.contains(c.id) }, set: { on in
                            if on { chosen.insert(c.id) } else { chosen.remove(c.id) }
                            UserDefaults.standard.set(Array(chosen).sorted(), forKey: CalendarSettings.reminderCalendarsKey)
                            reminders?.sync()
                        }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            Section("Privacy") {
                Toggle("Keep attendee email addresses", isOn: $keepEmails)
                    .onChange(of: keepEmails) { _, on in if !on, let store = library?.store { _ = try? CalendarLinking.forgetEmails(in: store) } }
                Text("Off: only invitees' names are saved with a meeting. On: their email addresses are kept too (never exported). Turning it off forgets the addresses already kept.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
                HStack {
                    Button("Remove Calendar Data from All Meetings…") { confirmingRemove = true }.disabled(library?.store == nil)
                    if let removedMessage { Text(removedMessage).font(.caption).foregroundStyle(Color.brandSecondary) }
                }
                Text("Unlinks every meeting and removes the people that came from calendar events. Names you typed stay, and so do speaker names you chose (rename speakers to change them). Turning calendar access off in System Settings doesn't remove what is already saved; this does.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { calendar.refresh(); chosen = CalendarSettings.reminderCalendars() }
        .confirmationDialog("Remove calendar data from all meetings?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let store = library?.store else { return }
                let n = (try? CalendarLinking.removeAllCalendarData(in: store)) ?? 0
                removedMessage = n == 1 ? "1 meeting updated" : "\(n) meetings updated"
                library?.reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Linked events and the people added from them are removed from every meeting. Names you typed stay. This can't be undone.")
        }
    }
}

/// Calendar access status with the one action that fits it.
struct CalendarAccessRow: View {
    var calendar: CalendarModel
    var recorder: RecorderModel

    var body: some View {
        LabeledContent("Calendar access") {
            HStack {
                Text(text).foregroundStyle(Color.brandSecondary)
                switch calendar.status.presentation {
                case .askOnClick:
                    Button("Allow Access…") { Task { await calendar.request(.userAction(recording: recorder.inSession)) } }
                        .disabled(recorder.inSession).help(recorder.inSession ? "Available after the recording" : "Shows the macOS permission prompt")
                case .off:
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(CalendarAuthorization.privacySettingsURL) }
                case .ready, .managed:
                    EmptyView()
                }
            }
        }
    }

    var text: String {
        switch calendar.status {
        case .notDetermined: "Not set up"
        case .fullAccess: "Allowed — read only, nothing leaves this Mac"
        case .denied, .writeOnly: "Off"
        case .restricted: "Managed by your administrator"
        }
    }
}
