import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Domain
import Presentation
import Export

struct MeetingDetailView: View {
    let detail: MeetingDetail
    @Environment(LibraryModel.self) private var library
    @Environment(PlaybackModel.self) private var playback
    @Environment(ModelSetupModel.self) private var models
    @State private var confirming: DestructiveAction?
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault

    var notesModelInstalled: Bool { if case .ready = models.status { true } else { false } }

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            header
            Picker("View", selection: $library.detailTab) { ForEach(LibraryModel.DetailTab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().help("Notes (⌘1) · Transcript (⌘2) · Recording (⌘3)").padding(.horizontal)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { detailsToggle.padding(.trailing) }
                .padding(.bottom, AppStyle.grid)
            Divider()
            switch library.detailTab {
            case .notes: NotesPane(detail: detail, notesModelInstalled: notesModelInstalled) { library.detailTab = .transcript }
            case .transcript: TranscriptPane(detail: detail)
            case .recording: RecordingDetailsPane(detail: detail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { loadPlayback() }
        .onChange(of: detail.meeting.id) { _, _ in loadPlayback() }
        .onChange(of: library.focusRowID) { _, id in if id != nil { library.detailTab = .transcript } }
        .focusedSceneValue(\.exportMarkdown, detail.transcript == nil ? nil : ExportAction { export(.markdown) })
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Markdown…") { export(.markdown) }
                    Button("Plain Text…") { export(.text) }
                    Button("JSON…") { export(.json) }
                    Divider()
                    Button("Original Audio…") { exportAudio() }.disabled(detail.playbackUnavailableReason != nil)
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(detail.transcript == nil)
                .help("Export the transcript and notes (Markdown: ⌘E). Your private scratchpad is not included.")
                Menu {
                    Button("Delete Audio Only…") { confirming = .deleteAudioOnly }.disabled(detail.meeting.audio == .deletedByUser)
                    Button("Delete Meeting…", role: .destructive) { confirming = .deleteMeeting }
                } label: { Label("Delete", systemImage: "trash") }
                .help("Delete this meeting's audio, or the whole meeting")
            }
        }
        .confirmationDialog(confirming?.confirmationTitle(detail.meeting.title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            Button(action.buttonTitle, role: .destructive) { playback.stop(); library.delete(action, detail.meeting.id) }
            Button("Cancel", role: .cancel) {}
        } message: { action in Text(action.explanation(detail.diskUsage)) }
    }

    /// The one place ⌘D is registered (the View menu item from T29 calls the same toggle).
    var detailsToggle: some View {
        Button { showDetails.toggle() } label: {
            Image(systemName: showDetails ? "info.circle.fill" : "info.circle").font(.system(size: AppStyle.iconLarge))
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("d", modifiers: .command)
        .help("Show details: where each note came from, transcript gaps and flags (⌘D)")   // View ▸ Show Details calls the same toggle
        .accessibilityLabel(showDetails ? "Hide details" : "Show details")
    }

    var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.half) {
            // Static: renaming lives in the sidebar card's context menu (T26).
            Text(detail.meeting.title).appFont(.title).lineLimit(1)
            HStack(spacing: AppStyle.grid) {
                // T50: small chips like Granola's header; the date is not editable. Narrow windows drop the time and the
                // calendar chip's words, then a linked event's title, before anything truncates.
                ViewThatFits(in: .horizontal) {
                    headerChips(compact: false)
                    headerChips(compact: true)
                    headerChips(compact: true, eventTitle: false)
                }
                Text(TranscriptRows.clock(SessionTime(nanoseconds: detail.meeting.duration.nanoseconds))).monospacedDigit().foregroundStyle(.secondary)
                // Quick review: one glyph (hover for its meaning); Details on: both full badges.
                if showDetails {
                    AudioBadge(headline: detail.status.audio)
                    ProcessingBadge(headline: detail.status.processing)
                } else {
                    MeetingStatusGlyph(status: detail.status)
                }
                Spacer()
                if case .failed = detail.status.processing { Button("Retry Processing") { library.retry(detail.meeting.id) }.help("Run the failed processing steps again") }
                if case .notQueued = detail.status.processing, detail.meeting.canPlayAudio { Button("Process") { library.process(detail.meeting.id) }.help("Transcribe, find speakers and write notes on this Mac") }
            }
            .appFont(.callout)
        }
        .padding(.horizontal, AppStyle.double).padding(.top, AppStyle.grid + 4).padding(.bottom, AppStyle.grid)
    }

    /// `eventTitle: false` is the narrowest variant: a linked event shows as its icon only (the tooltip names it).
    func headerChips(compact: Bool, eventTitle: Bool = true) -> some View {
        HStack(spacing: AppStyle.grid) {
            HeaderChip(symbol: "calendar", text: detail.meeting.createdAt.formatted(date: .abbreviated, time: compact ? .omitted : .shortened))
                .help("Recorded \(detail.meeting.createdAt.formatted(date: .complete, time: .shortened))")
            PeopleChip(meeting: detail.meeting).id(detail.meeting.id)
            CalendarLinkChip(meeting: detail.meeting, compact: compact, iconOnly: !eventTitle).id(detail.meeting.id)
        }
        .fixedSize()
    }

    func loadPlayback() {
        playback.load(meetingDirectory: library.store!.meetingDirectory(detail.meeting.id), segments: detail.segments)
    }

    enum Format { case markdown, text, json }

    func exportInput() -> ExportInput? {
        guard let t = detail.displayTranscript else { return nil }
        return ExportInput(meeting: detail.meeting, transcript: t, summary: detail.summary, userNotes: detail.userNotes, scratchpad: detail.scratchpad)
    }

    func export(_ f: Format) {
        guard let input = exportInput() else { return }
        let panel = NSSavePanel()
        let base = detail.meeting.title.replacingOccurrences(of: "/", with: "-")
        switch f {
        case .markdown: panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = base + ".md"
        case .text: panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = base + ".txt"
        case .json: panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = base + ".json"
        }
        panel.message = "Exports the transcript and notes shown. The private scratchpad is not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data = switch f {
            case .markdown: Data(Exporter.markdown(input).utf8)
            case .text: Data(Exporter.text(input).utf8)
            case .json: try Exporter.json(input)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportAudio() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Audio Here"
        panel.message = "Copies the original audio segments with a manifest of their times and any gaps."
        guard panel.runModal() == .OK, let dir = panel.url, let store = library.store else { return }
        do {
            _ = try Exporter.exportAudio(meetingDirectory: store.meetingDirectory(detail.meeting.id), meetingID: detail.meeting.id,
                                         segments: detail.segments, events: detail.events,
                                         to: dir.appending(path: detail.meeting.title.replacingOccurrences(of: "/", with: "-") + " audio"))
        } catch { NSAlert(error: error).runModal() }
    }
}

/// One header chip (T50): icon + short text in a capsule. `.inert` is for placeholders: no fill, dashed outline,
/// tertiary text, so it never reads as a control.
struct HeaderChip: View {
    enum Style { case info, action, inert }
    let symbol: String
    let text: String
    var style: Style = .info
    var hovering = false
    /// Changed or missing calendar event (T57): text and icon in the attention colour.
    var attention = false

    var body: some View {
        HStack(spacing: AppStyle.half) {
            Image(systemName: symbol).font(.system(size: AppStyle.iconSmall))
            if !text.isEmpty { Text(text).lineLimit(1) }
        }
        .appFont(.callout)
        .foregroundStyle(attention ? AnyShapeStyle(Color.statusAttention) : style == .inert ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, AppStyle.grid).padding(.vertical, 3)
        .background {
            if style != .inert { Capsule().fill(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary)) }
        }
        .overlay {
            if style == .inert { Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])) }
        }
        .contentShape(Capsule())
    }
}

/// People in the meeting (T50): click to edit the names in a popover. Saved through `LibraryModel.setPeople` (T49).
struct PeopleChip: View {
    let meeting: Meeting
    @Environment(LibraryModel.self) private var library
    @State private var editing = false
    @State private var hovering = false

    /// A linked event's invitees without a name (T58), counted but never stored.
    var unnamed: Int { meeting.linkedEvent?.unnamedAttendees ?? 0 }

    var body: some View {
        Button { editing = true } label: {
            HeaderChip(symbol: "person.2", text: MeetingPeople.chipLabel(meeting.people, unnamed: unnamed), style: .action, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(meeting.people.isEmpty && unnamed == 0 ? "Add the people in this meeting" : MeetingPeople.fullList(meeting.people, unnamed: unnamed) + " (click to edit)")
        .accessibilityLabel(MeetingPeople.fullList(meeting.people, unnamed: unnamed))
        .accessibilityHint("Edit the people in this meeting")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            PeopleEditor(people: meeting.people) { people in
                library.setPeople(meeting.id, people)
                editing = false
            } cancel: { editing = false }
        }
    }
}

/// The names editor in the people chip's popover: one name per line or comma-separated.
struct PeopleEditor: View {
    let people: [Person]
    let save: ([Person]) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Field?
    enum Field { case names }

    init(people: [Person], save: @escaping ([Person]) -> Void, cancel: @escaping () -> Void) {
        self.people = people
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: MeetingPeople.editableText(people))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            Text("People").appFont(.headline)
            TextEditor(text: $text).appFont(.body).scrollIndicators(.never).frame(width: 260, height: 110)
                .editableField(focused: $focused, as: .names, isEmpty: text.isEmpty, placeholder: "One name per line, or separated by commas")
            if !MeetingPeople.calendarNames(people).isEmpty {
                Label("From the calendar: " + MeetingPeople.calendarNames(people).joined(separator: ", "), systemImage: "calendar")
                    .appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Added from the linked event. Unlinking keeps them; delete any you don't want here.")
            }
            Text("Saved with this meeting and included in exports.").appFont(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(MeetingPeople.parse(text, keeping: people)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Save (⌘↩)")
            }
        }
        .padding(12)
        .onAppear { focused = .names }
    }
}

/// Recording details: sources, gaps, interruptions and disk use — so silence is never mistaken for certainty.
struct RecordingDetailsPane: View {
    let detail: MeetingDetail

    var body: some View {
        Form {
            Section("Audio") {
                LabeledContent("Audio", value: detail.meeting.audio == .present ? "Kept on this Mac until you delete it" : "Deleted")
                LabeledContent("Disk use", value: ByteCountFormatter.string(fromByteCount: detail.diskUsage.totalBytes, countStyle: .file))
                LabeledContent("Sources", value: Set(detail.segments.map(\.source)).map { $0 == .microphone ? "Microphone" : "System audio" }.sorted().joined(separator: ", "))
            }
            Section("Events (\(detail.events.count))") {
                if detail.events.isEmpty { Text("No interruptions, gaps or device changes.").foregroundStyle(.secondary) }
                ForEach(detail.events) { e in
                    HStack {
                        Text(TranscriptRows.clock(e.interval.start)).monospacedDigit().frame(width: 70, alignment: .leading)
                        Text(Self.describe(e))
                        Spacer()
                        Text(e.source.map { $0 == .microphone ? "mic" : "system" } ?? "all").foregroundStyle(Color(nsColor: .secondaryLabelColor))   // grey even on attention rows
                    }
                    .foregroundStyle(e.isMissingAudio ? Color.statusAttention : .primary)
                }
            }
        }
        .formStyle(.grouped)
    }

    static func describe(_ e: CaptureEvent) -> String {
        let d = e.interval.duration.seconds
        let len = d >= 0.5 ? String(format: " (%.1f s)", d) : ""
        return switch e.kind {
        case .gap, .overrun: "Audio missing\(len) — \(e.reasonCode)"
        case .pause: "Paused\(len)"
        case .resume: "Resumed"
        case .deviceChange: "Device changed — \(e.reasonCode)"
        case .formatChange: "Audio format changed — \(e.reasonCode)"
        case .sleep: "Mac went to sleep"
        case .wake: "Mac woke"
        case .sourceFault: "Source stopped delivering audio\(len)"
        default: "\(e.kind.rawValue)\(len) — \(e.reasonCode)"
        }
    }
}
