import SwiftUI
import AppKit
import Presentation

/// Settings → Calendar (T59; T61 adds the reminder and data controls). Turning a calendar feature on is a user action,
/// so it may show the system prompt (never while recording).
struct CalendarSettingsView: View {
    var calendar: CalendarModel
    var recorder: RecorderModel
    @AppStorage(CalendarSettings.suggestKey) private var suggest = CalendarSettings.suggestDefault

    var body: some View {
        Form {
            Section {
                CalendarAccessRow(calendar: calendar, recorder: recorder)
                Toggle("Suggest calendar events when recording", isOn: $suggest)
                    .onChange(of: suggest) { _, on in if on { Task { await calendar.request(.userAction(recording: recorder.inSession)) } } }
                Text("When you press Record during (or up to 10 minutes before) an event, the recording bar asks whether this is that meeting. Nothing is linked or renamed unless you choose Link, and the event's title is used only if you didn't type one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { calendar.refresh() }
    }
}

/// Calendar access status with the one action that fits it.
struct CalendarAccessRow: View {
    var calendar: CalendarModel
    var recorder: RecorderModel

    var body: some View {
        LabeledContent("Calendar access") {
            HStack {
                Text(text).foregroundStyle(.secondary)
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
