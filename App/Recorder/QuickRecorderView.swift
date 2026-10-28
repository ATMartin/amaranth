import SwiftUI
import AppKit
import Capture
import Domain
import Presentation

/// Toolbar recorder (T31): a Record button that starts at once with the Settings defaults, plus a chevron opening this
/// meeting's options. While a recording session is open it becomes the compact recording strip. A SwiftUI toolbar
/// Menu can't hold a text field, so the options are a popover (the task's fallback: button + adjacent chevron).
struct RecordToolbarControl: View {
    @Bindable var model: RecorderModel
    @State private var showingOptions = false

    var body: some View {
        if model.inSession {
            RecordingStrip(model: model)
        } else {
            idle.toolbarSized()
        }
    }

    /// Two plain buttons in one toolbar item: a ControlGroup here was moved to the trailing edge and truncated.
    var idle: some View {
        HStack(spacing: 2) {
                // The handoff's Record button (T76): a squarer outlined button on Surface, a Danger dot, "Record".
                Button { model.start() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.statusFailed).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text("Record").foregroundStyle(Color.brandText)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.controlBorder, lineWidth: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record")
                .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Record a new meeting (⌘⇧R). \(RecorderPresentation.consent)")
                Button { showingOptions.toggle() } label: { Image(systemName: "chevron.down").padding(.horizontal, 4).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Color.brandSecondary)
                    .accessibilityLabel("Recording options")
                    .help("Title, sources and microphone for this meeting")
                    .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                        RecordOptionsForm(model: model) { showingOptions = false; model.start() }
                    }
        }
    }
}

/// This meeting's title, sources and microphone. Changes apply to the next recording only; Settings keeps the defaults.
/// The handoff's focused setup surface: a heading, labelled fields, where the audio goes, and one primary action.
struct RecordOptionsForm: View {
    @Bindable var model: RecorderModel
    let record: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.double) {
            Text("New recording").appFont(.title).foregroundStyle(Color.brandText).accessibilityAddTraits(.isHeader)
            field("Meeting name") {
                TextField("Meeting name", text: $model.title, prompt: Text(RecorderPresentation.automaticTitle(Date())))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit(record)
            }
            field("Record") {
                Picker("Record", selection: $model.selection) {
                    Text("Microphone + system audio").tag(SourceSelection.both)
                    Text("Microphone only").tag(SourceSelection.microphoneOnly)
                    Text("System audio only").tag(SourceSelection.systemOnly)
                }
                .labelsHidden()
            }
            field("Microphone") {
                Picker("Microphone", selection: $model.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.inputs) { d in Text("\(d.name) (\(d.transportName))").tag(Optional(d.uid)) }
                    if let uid = model.microphoneUID, !model.inputs.contains(where: { $0.uid == uid }) {
                        Text("Not connected (uses System default)").tag(Optional(uid))
                    }
                }
                .labelsHidden()
                .disabled(model.selection == .systemOnly)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio and transcription stay on this Mac.").foregroundStyle(Color.statusOK)
                Text("For this meeting only. A blank name is filled in with the date and time.").foregroundStyle(Color.brandSecondary)
            }
            .appFont(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Recording Settings…") { openSettings(.recording) }.buttonStyle(.brandLink).appFont(.caption)
                if model.customized { Button("Use Defaults") { model.loadDefaults() }.buttonStyle(.brandLink).appFont(.caption) }
                Spacer()
                Button(action: record) {
                    HStack(spacing: 6) { Circle().frame(width: 8, height: 8).accessibilityHidden(true); Text("Start recording") }
                }
                .buttonStyle(.brandProminent)
                .keyboardShortcut(.defaultAction)
                .help(RecorderPresentation.consent)
            }
        }
        .padding(AppStyle.double + 4)
        .frame(width: 360)
        .background(Color.surface)
        .onAppear { model.refreshDevices() }
    }

    func field<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.half + 2) {
            Text(label).appFont(.caption, weight: .medium).foregroundStyle(Color.brandText).accessibilityHidden(true)
            control().accessibilityLabel(label)
        }
    }
}

extension View {
    /// Toolbar recorder text and controls a step smaller than the defaults, so the Record button and the strip stay compact.
    func toolbarSized() -> some View { font(.system(size: AppStyle.toolbarText)).controlSize(.small) }
}

/// The compact toolbar strip while recording: state and elapsed time, one health glyph per source, the disk warning,
/// Pause/Resume and Stop and Save.
struct RecordingStrip: View {
    @Bindable var model: RecorderModel

    var body: some View {
        RecordingStripContent(state: model.state, elapsed: model.elapsed, health: model.health, savedUpTo: model.savedUpTo,
                              diskWarning: model.diskWarned ? model.diskSecondsLeft.map(RecorderPresentation.diskWarning) : nil,
                              folder: model.directory?.path, pause: model.pause, resume: model.resume, stop: model.stop,
                              eventPrompt: model.eventPrompt, link: model.approve, dismissEvent: model.dismissEventPrompt,
                              quiet: model.quiet, keepRecording: model.keepRecording)
    }
}

/// Value-only strip, so the UI render self-test can show every state without a capture session.
struct RecordingStripContent: View {
    let state: CaptureState
    let elapsed: Double
    let health: [SourceHealth]
    let savedUpTo: [SourceKind: Double]
    let diskWarning: String?
    let folder: String?
    let pause: () -> Void
    let resume: () -> Void
    let stop: () -> Void
    var eventPrompt: CalendarSuggestion.Prompt = .none
    var link: (CalendarEvent) -> Void = { _ in }
    var dismissEvent: () -> Void = {}
    /// T68: the "Still recording?" alert, shown as an amber "Quiet 1:12" in place of the clock; a click offers Keep Recording.
    var quiet: QuietMonitor.Alert? = nil
    var keepRecording: () -> Void = {}
    @State private var showingHealth = false
    @State private var showingQuiet = false

    var body: some View {
        HStack(spacing: AppStyle.grid) {
            status
            // The glyphs open the detailed health popover (T34); each glyph's tooltip still names its status.
            Button { showingHealth.toggle() } label: {
                HStack(spacing: 6) {
                    ForEach(health, id: \.source) { h in SourceHealthGlyph(health: h, savedUpTo: savedUpTo[h.source], now: elapsed) }
                    if let diskWarning {
                        Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(Color.statusAttention)
                            .help(diskWarning).accessibilityLabel(diskWarning)
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(health.isEmpty && diskWarning == nil)
            .accessibilityHint("Shows levels, devices and where the recording is saved")
            .popover(isPresented: $showingHealth, arrowEdge: .bottom) {
                RecordingHealthDetails(health: health, savedUpTo: savedUpTo, now: elapsed, diskWarning: diskWarning, folder: folder)
            }
            // Pause/Resume is icon-only (T45; tooltip and VoiceOver say which); Stop and Save keeps its words because it
            // ends the recording.
            if state == .paused || state == .interrupted {
                Button(action: resume) { Label("Resume", systemImage: "play.fill").labelStyle(.iconOnly) }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).help("Resume recording (⌘⇧P)")
            } else {
                Button(action: pause) { Label("Pause", systemImage: "pause.fill").labelStyle(.iconOnly) }.disabled(state != .recording)
                    .keyboardShortcut("p", modifiers: [.command, .shift]).help("Pause recording (⌘⇧P)")
            }
            Button(action: stop) { Label("Stop and Save", systemImage: "stop.fill") }.disabled(state == .stopping || state == .preparing)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help(quiet != nil ? "Stop and make notes (⌘⇧S): the meeting ends 5 seconds after the last words; the quiet audio after that is deleted"
                                   : "Stop and save (⌘⇧S)")
            if eventPrompt != .none {
                // Icon only while "Quiet" shows: both don't fit beside Stop at a 900 pt window.
                EventPromptContent(prompt: eventPrompt, link: link, dismiss: dismissEvent, compact: quiet != nil)
            }
        }
        .labelStyle(.titleAndIcon)
        .toolbarSized()
        // Keeps the leading red dot and the Stop button inside the toolbar item's capsule.
        .padding(.horizontal, AppStyle.half + 2)
        .fixedSize()
    }

    @ViewBuilder var status: some View {
        let clock = RecorderPresentation.clock(elapsed)
        switch state {
        case .recording where quiet != nil:
            let q = quiet!
            Button { showingQuiet.toggle() } label: {
                Label { Text(QuietMonitor.stripLabel(q, now: elapsed)).monospacedDigit() } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Color.statusAttention)
                }
                .foregroundStyle(Color.statusAttention)
            }
            .buttonStyle(.plain)
            .help("Still recording (\(clock)) — \(q.reason == .quiet ? "no one has spoken for a while" : "the call seems to have ended"). Click for options.")
            .accessibilityLabel("Still recording? \(QuietMonitor.stripLabel(q, now: elapsed)), recording \(clock)")
            .popover(isPresented: $showingQuiet, arrowEdge: .bottom) {
                QuietAlertDetails(alert: q, now: elapsed, stop: { showingQuiet = false; stop() },
                                  keep: { showingQuiet = false; keepRecording() })
            }
        case .recording:
            Label { Text(clock).monospacedDigit() } icon: { Image(systemName: "circle.fill").foregroundStyle(Color.statusFailed) }
                .help("Recording").accessibilityLabel("Recording, \(clock)")
        case .paused:
            Label { Text(clock).monospacedDigit() } icon: { Image(systemName: "pause.circle.fill") }
                .foregroundStyle(Color.brandSecondary).help("Paused — nothing is being recorded").accessibilityLabel("Paused at \(clock)")
        case .interrupted:
            Label("Interrupted", systemImage: "moon.zzz").foregroundStyle(Color.statusAttention).help("Interrupted by sleep · audio so far is saved")
        case .stopping: Label("Saving…", systemImage: "arrow.down.circle").foregroundStyle(Color.brandSecondary)
        default: Label("Starting…", systemImage: "hourglass").foregroundStyle(Color.brandSecondary).help("Starting… waiting for audio")
        }
    }
}

/// T68: what the amber "Quiet" means, and the two choices the notification also offers.
struct QuietAlertDetails: View {
    let alert: QuietMonitor.Alert
    let now: Double
    let stop: () -> Void
    let keep: () -> Void

    var body: some View {
        let text = QuietMonitor.notification(alert, now: now)
        VStack(alignment: .leading, spacing: 8) {
            Text(text.title).font(.headline)
            Text(text.body)
            Text("Stopping now ends the meeting 5 seconds after the last words and deletes the quiet audio after that. Amaranth never stops on its own.")
                .font(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep Recording", action: keep)
                Button("Stop & Make Notes", action: stop)   // no default button: Return must not delete the quiet end
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// The calendar question after Record (T59): one compact button in the strip, never acting on its own. One match reads
/// "<title>?", several "Which meeting?"; the click opens the choices (Link / Not this, or each event and None) with the
/// full title and time. The strip has about 100 pt to spare at a 900 pt window, so the buttons can't sit inline.
/// Ignoring it changes nothing.
struct EventPromptContent: View {
    let prompt: CalendarSuggestion.Prompt
    let link: (CalendarEvent) -> Void
    let dismiss: () -> Void
    /// Just the calendar icon (the question is in the tooltip and VoiceOver label).
    var compact = false
    @State private var open = false

    var label: String {
        switch prompt {
        case .one(let e): CalendarSuggestion.question(e)
        case .several: "Which event?"
        case .none: ""
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "calendar").foregroundStyle(Color.brandAccent)
                if !compact { Text(label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 74, alignment: .leading) }
            }
        }
        .help(prompt == .none ? "" : (compact ? label + " " : "") + "Is this recording a calendar event? Click to link it, or dismiss. Nothing changes until you choose.")
        .accessibilityLabel("Calendar suggestion: \(label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            EventPromptChoices(prompt: prompt, link: { open = false; link($0) }, dismiss: { open = false; dismiss() })
        }
    }
}

/// The prompt's choices (T59), also rendered by ui-render.
struct EventPromptChoices: View {
    let prompt: CalendarSuggestion.Prompt
    let link: (CalendarEvent) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            switch prompt {
            case .one(let e):
                Text("Is this “\(e.title.isEmpty ? "Untitled event" : e.title)”?").appFont(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail(e)).appFont(.caption).foregroundStyle(Color.brandSecondary)
                HStack {
                    Spacer()
                    Button("Not this", action: dismiss)
                    Button("Link") { link(e) }.buttonStyle(.brandProminent)
                }
            case .several(let events):
                Text("Which meeting?").appFont(.headline)
                ForEach(events) { e in CalendarEventRow(event: e) { link(e) } }
                HStack { Spacer(); Button("None", action: dismiss) }
            case .none:
                EmptyView()
            }
            Text("Linking adds the invited names; the event's title is used only if you didn't type one.")
                .appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    func detail(_ e: CalendarEvent) -> String {
        [CalendarLinking.timeRange(start: e.start, end: e.end), e.calendarName].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Recording health on demand (T34): per source the level meter, status, device and "saved up to"; the disk warning;
/// and the meeting folder. Meters update with the recorder's 10 Hz poll (which also drives the strip glyphs).
struct RecordingHealthDetails: View {
    let health: [SourceHealth]
    let savedUpTo: [SourceKind: Double]
    let now: Double
    let diskWarning: String?
    let folder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording health").font(.headline)
            ForEach(health, id: \.source) { h in
                VStack(alignment: .leading, spacing: 2) {
                    SourceHealthRow(health: h, savedUpTo: savedUpTo[h.source], now: now)
                    Text([RecorderPresentation.sourceName(h.source) + ": " + (h.deviceName ?? "device unknown"),
                          savedUpTo[h.source].map { "saved up to \(RecorderPresentation.clock($0))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.brandSecondary).padding(.leading, 36)
                }
            }
            if let diskWarning {
                Label(diskWarning, systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(Color.statusAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let folder {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving to").font(.caption).foregroundStyle(Color.brandSecondary)
                    Text(folder).font(.caption.monospaced()).foregroundStyle(Color.brandSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }
}

/// One source's health as a small coloured glyph; the tooltip (and VoiceOver label) carries the details.
struct SourceHealthGlyph: View {
    let health: SourceHealth
    let savedUpTo: Double?
    let now: Double

    var body: some View {
        let tip = RecorderPresentation.tooltip(health, savedUpTo: savedUpTo, now: now)
        Image(systemName: RecorderPresentation.symbol(health.source))
            .foregroundStyle(Self.color(RecorderPresentation.tone(health.status)))
            .frame(width: 18)
            .help(tip)
            .accessibilityElement()
            .accessibilityLabel(tip)
    }

    static func color(_ t: RecorderPresentation.Tone) -> Color {
        Color.status(t)
    }
}

/// Recorder messages at the top of the detail pane: errors in red, everything else secondary; each can be dismissed.
struct RecorderBanner: View {
    @Bindable var model: RecorderModel

    var body: some View {
        RecorderBannerContent(items: model.bannerItems, dismiss: model.dismiss)
    }
}

struct RecorderBannerContent: View {
    let items: [RecorderModel.BannerItem]
    let dismiss: (RecorderModel.Message) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.kind) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.symbol).foregroundStyle(item.isError ? Color.statusFailed : Color.brandSecondary)
                        Text(item.text).foregroundStyle(item.isError ? Color.statusFailed : Color.brandSecondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if item.kind == .permission {
                            Button("Open Privacy Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                            }
                        }
                        Button { dismiss(item.kind) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct SourceHealthRow: View {
    let health: SourceHealth
    var savedUpTo: Double? = nil
    var now: Double = 0

    var body: some View {
        HStack {
            SourceIcon(source: health.source).frame(width: 28)
            MeterBar(db: health.peakLevelDBFS ?? -120)
            Text(statusText).font(.caption2).foregroundStyle(statusColor).frame(width: 150, alignment: .leading)
        }
        .help([health.deviceName, savedUpTo.map { "Saved up to \(RecorderPresentation.clock($0))" }].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RecorderPresentation.sourceName(health.source)): \(statusText)")
    }

    var statusText: String { RecorderPresentation.statusText(health.status, savedUpTo: savedUpTo, now: now) }

    var statusColor: Color {
        switch RecorderPresentation.tone(health.status) {
        case .orange, .red: Color.status(RecorderPresentation.tone(health.status))
        default: Color.brandSecondary
        }
    }
}

struct MeterBar: View {
    let db: Float
    var body: some View {
        GeometryReader { g in
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(db > -3 ? Color.statusAttention : Color.statusOK).frame(width: g.size.width * frac)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
