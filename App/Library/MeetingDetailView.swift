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
            Image(systemName: showDetails ? "info.circle.fill" : "info.circle").imageScale(.large)
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
            HStack(spacing: 16) {
                Text(detail.meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
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
                        Text(e.source.map { $0 == .microphone ? "mic" : "system" } ?? "all").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(e.isMissingAudio ? .orange : .primary)
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
