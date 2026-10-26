import SwiftUI
import Domain
import Presentation
import Storage

struct MainView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RecorderModel.self) private var recorder
    @Environment(ModelSetupModel.self) private var models
    @State private var showingModels = false
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            Group {
                if recorder.inSession, library.selection == nil || library.selection == recorder.meetingID {
                    LiveTranscriptView()
                } else if let d = library.detail {
                    MeetingDetailView(detail: d)
                } else {
                    ContentUnavailableView {
                        Label("No meeting selected", systemImage: "waveform")
                    } description: {
                        Text("Press Record to capture a meeting. Audio stays on this Mac.")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { RecorderBanner(model: recorder) }
        }
        .environment(\.showDetails, showDetails)
        .searchable(text: $library.query, placement: .sidebar, prompt: "Search transcripts and notes")
        .searchFocused($searchFocused)
        .onChange(of: library.searchFocusRequest) { _, _ in searchFocused = true }
        .toolbar {
            ToolbarItem(placement: .navigation) { RecordToolbarControl(model: recorder).fixedSize() }
            ToolbarItem(placement: .navigation) {
                Button { showingModels = true } label: {
                    if case .ready = models.status { Label("Models ready", systemImage: "checkmark.seal") }
                    else if case .installing = models.status { Label("Installing models…", systemImage: "arrow.down.circle") }
                    else { Label("Record-only — install models", systemImage: "arrow.down.circle") }
                }
                .help("Local speech and notes models")
            }
        }
        .sheet(isPresented: $showingModels) {
            ModelSetupView(model: models)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingModels = false } } }
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.error != nil }, set: { _ in })) {
            Button("OK") { library.dismissError() }
        } message: { Text(library.error ?? "") }
    }
}

struct LibrarySidebar: View {
    @Environment(LibraryModel.self) private var library
    @State private var confirming: (DestructiveAction, MeetingListItem)?
    @State private var renaming: MeetingListItem?
    @State private var newTitle = ""

    var body: some View {
        @Bindable var library = library
        List(selection: $library.selection) {
            if !library.query.isEmpty {
                Section("Results") {
                    if library.hits.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                    ForEach(Array(library.hits.enumerated()), id: \.offset) { _, hit in
                        Button { library.open(hit) } label: { SearchHitRow(hit: hit) }.buttonStyle(.plain)
                    }
                }
            }
            Section("Meetings") {
                if library.items.isEmpty { Text("No recordings yet.").foregroundStyle(.secondary) }
                ForEach(library.items) { item in
                    MeetingRow(item: item).tag(item.id)
                        .contextMenu {
                            Button("Rename…") { newTitle = item.title; renaming = item }
                            Divider()
                            Button("Delete Audio Only…") { confirming = (.deleteAudioOnly, item) }.disabled(item.status.audio == .audioDeleted)
                            Button("Delete Meeting…", role: .destructive) { confirming = (.deleteMeeting, item) }
                        }
                }
            }
        }
        .sheet(item: $renaming) { item in
            EditTextSheet(title: "Rename Meeting", text: $newTitle, help: "Shown in the meeting list, the meeting header, search and exports.") {
                library.rename(item.id, to: newTitle)
            }
        }
        .confirmationDialog(confirming.map { $0.0.confirmationTitle($0.1.title) } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { c in
            Button(c.0.buttonTitle, role: .destructive) { library.delete(c.0, c.1.id) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.0.explanation(library.store?.diskUsage(c.1.id) ?? .init(originalAudioBytes: 0, derivedBytes: 0)))
        }
    }
}

/// Meeting card (T27): title with one status glyph, and one caption line "Oct 23, 2026 at 10:01 AM · 49:36".
struct MeetingRow: View {
    let item: MeetingListItem
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title).appFont(.headline).lineLimit(1)
                Spacer(minLength: 4)
                MeetingStatusGlyph(status: item.status)
            }
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened) + " · "
                 + TranscriptRows.clock(SessionTime(nanoseconds: item.duration.nanoseconds)))
                .appFont(.caption, monospacedDigit: true).foregroundStyle(.secondary)
        }
    }
}

/// The single status glyph of a meeting; the tooltip is also its VoiceOver label.
struct MeetingStatusGlyph: View {
    let status: MeetingStatus
    var body: some View {
        let g = MeetingStatusPresentation.glyph(status)
        Group {
            if g.spinner { ProgressView().controlSize(.small).scaleEffect(0.6) }
            else if let s = g.symbol { Image(systemName: s).foregroundStyle(color(g.tone)) }
        }
        .frame(width: 16, height: 16)
        .help(g.tooltip)
        .accessibilityElement()
        .accessibilityLabel(g.tooltip)
    }

    func color(_ t: MeetingStatusPresentation.Tone) -> Color {
        switch t { case .secondary: .secondary; case .red: .red; case .orange: .orange }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.meetingTitle).appFont(.caption, weight: .bold)
                Spacer()
                Text(kind).appFont(.caption2).foregroundStyle(.secondary)
            }
            Text(highlighted).appFont(.callout).lineLimit(2)
        }
    }
    var kind: String {
        switch hit.kind {
        case .title: "title"
        case .transcript: hit.start.map { TranscriptRows.clock($0) } ?? "transcript"
        case .notes: "notes"
        case .userNotes: "your notes"
        }
    }
    /// Snippet with the `[match]` markers rendered bold.
    var highlighted: AttributedString {
        var out = AttributedString()
        var bold = false
        for part in hit.snippet.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "[" || $0 == "]" }) {
            var a = AttributedString(String(part))
            if bold { a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
            bold.toggle()
        }
        return out
    }
}

struct AudioBadge: View {
    let headline: MeetingStatus.AudioHeadline
    var body: some View {
        switch headline {
        case .saved: Label("Audio saved", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .savedWithGaps(let s): Label("Audio saved · \(Int(s.rounded())) s missing", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .recording: Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
        case .paused: Label("Paused", systemImage: "pause.circle")
        case .saving: Label("Saving…", systemImage: "arrow.down.circle")
        case .interrupted: Label("Interrupted — audio up to the interruption is saved", systemImage: "bolt.horizontal.circle").foregroundStyle(.orange)
        case .notStarted: Label("No audio", systemImage: "circle")
        case .audioDeleted: Label("Audio deleted", systemImage: "trash.circle").foregroundStyle(.secondary)
        }
    }
}

struct ProcessingBadge: View {
    let headline: MeetingStatus.ProcessingHeadline
    var body: some View {
        Group {
            switch headline {
            case .notQueued: Label("Not processed", systemImage: "circle.dashed")
            case .waiting(let reason):
                Label(MeetingStatusPresentation.waiting(reason), systemImage: "hourglass")
            case .running(let stage, let p): Label("\(Self.stageName(stage)) \(Int(p * 100))%", systemImage: "gearshape.2")
            case .complete: Label("Processed", systemImage: "doc.text")
            case .failed(let stage, _):
                Label("\(Self.stageName(stage)) failed — retry available", systemImage: "xmark.octagon").foregroundStyle(.red)
            case .cancelled(let stage): Label("\(Self.stageName(stage)) stopped", systemImage: "stop.circle")
            }
        }
        .appFont(.caption)
    }

    static func stageName(_ s: ProcessingStage) -> String { MeetingStatusPresentation.stageName(s) }
}
