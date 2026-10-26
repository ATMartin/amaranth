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
            // Two plain buttons in one toolbar item: a ControlGroup here was moved to the trailing edge and truncated.
            HStack(spacing: 2) {
                Button { model.start() } label: {
                    HStack(spacing: 4) { Image(systemName: "record.circle").foregroundStyle(Color.statusFailed); Text("Record") }
                }
                .accessibilityLabel("Record")
                .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Record a new meeting (⌘⇧R). \(RecorderPresentation.consent)")
                Button { showingOptions.toggle() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Recording options")
                    .help("Title, sources and microphone for this meeting")
                    .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                        RecordOptionsForm(model: model) { showingOptions = false; model.start() }
                    }
            }
        }
    }
}

/// This meeting's title, sources and microphone. Changes apply to the next recording only; Settings keeps the defaults.
struct RecordOptionsForm: View {
    @Bindable var model: RecorderModel
    let record: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $model.title, prompt: Text(RecorderPresentation.automaticTitle(Date())))
                .textFieldStyle(.roundedBorder)
                .onSubmit(record)
            Picker("Record", selection: $model.selection) {
                Text("Microphone + system audio").tag(SourceSelection.both)
                Text("Microphone only").tag(SourceSelection.microphoneOnly)
                Text("System audio only").tag(SourceSelection.systemOnly)
            }
            Picker("Microphone", selection: $model.microphoneUID) {
                Text("System default").tag(String?.none)
                ForEach(model.inputs) { d in Text("\(d.name) (\(d.transportName))").tag(Optional(d.uid)) }
                if let uid = model.microphoneUID, !model.inputs.contains(where: { $0.uid == uid }) {
                    Text("Not connected (uses System default)").tag(Optional(uid))
                }
            }
            .disabled(model.selection == .systemOnly)
            Text("For this meeting only. A blank title is filled in with the date and time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SettingsLink { Text("Recording Settings…") }
                if model.customized { Button("Use Defaults") { model.loadDefaults() } }
                Spacer()
                Button(action: record) { Label("Record", systemImage: "record.circle") }
                    .keyboardShortcut(.defaultAction)
                    .help(RecorderPresentation.consent)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refreshDevices() }
    }
}

/// The compact toolbar strip while recording: state and elapsed time, one health glyph per source, the disk warning,
/// Pause/Resume and Stop and Save.
struct RecordingStrip: View {
    @Bindable var model: RecorderModel

    var body: some View {
        RecordingStripContent(state: model.state, elapsed: model.elapsed, health: model.health, savedUpTo: model.savedUpTo,
                              diskWarning: model.diskWarned ? model.diskSecondsLeft.map(RecorderPresentation.diskWarning) : nil,
                              folder: model.directory?.path, pause: model.pause, resume: model.resume, stop: model.stop)
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
    @State private var showingHealth = false

    var body: some View {
        HStack(spacing: 10) {
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
            if state == .paused || state == .interrupted {
                Button(action: resume) { Label("Resume", systemImage: "play.fill") }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).help("Resume recording (⌘⇧P)")
            } else {
                Button(action: pause) { Label("Pause", systemImage: "pause.fill") }.disabled(state != .recording)
                    .keyboardShortcut("p", modifiers: [.command, .shift]).help("Pause recording (⌘⇧P)")
            }
            Button(action: stop) { Label("Stop and Save", systemImage: "stop.fill") }.disabled(state == .stopping || state == .preparing)
                .keyboardShortcut("s", modifiers: [.command, .shift]).help("Stop and save (⌘⇧S)")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    @ViewBuilder var status: some View {
        let clock = RecorderPresentation.clock(elapsed)
        switch state {
        case .recording:
            Label { Text(clock).monospacedDigit() } icon: { Image(systemName: "circle.fill").foregroundStyle(Color.statusFailed) }
                .help("Recording").accessibilityLabel("Recording, \(clock)")
        case .paused:
            Label { Text(clock).monospacedDigit() } icon: { Image(systemName: "pause.circle.fill") }
                .foregroundStyle(.secondary).help("Paused — nothing is being recorded").accessibilityLabel("Paused at \(clock)")
        case .interrupted:
            Label("Interrupted", systemImage: "moon.zzz").foregroundStyle(Color.statusAttention).help("Interrupted by sleep · audio so far is saved")
        case .stopping: Label("Saving…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        default: Label("Starting…", systemImage: "hourglass").foregroundStyle(.secondary).help("Starting… waiting for audio")
        }
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
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 36)
                }
            }
            if let diskWarning {
                Label(diskWarning, systemImage: "externaldrive.badge.exclamationmark").font(.caption).foregroundStyle(Color.statusAttention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let folder {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving to").font(.caption).foregroundStyle(.secondary)
                    Text(folder).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
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
                        Image(systemName: item.symbol).foregroundStyle(item.isError ? Color.statusFailed : .secondary)
                        Text(item.text).foregroundStyle(item.isError ? Color.statusFailed : .secondary).textSelection(.enabled)
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
            Text(health.source == .microphone ? "MIC" : "SYS").font(.caption2.bold()).frame(width: 28)
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
        default: .secondary
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
