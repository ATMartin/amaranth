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

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                .safeAreaInset(edge: .top) { RecorderPanel(model: recorder).padding(8) }
        } detail: {
            if recorder.state.isActive, library.selection == nil || library.selection == recorder.meetingID {
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
        .environment(\.showDetails, showDetails)
        .searchable(text: $library.query, placement: .sidebar, prompt: "Search transcripts and notes")
        .toolbar {
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
                            Button("Delete Audio Only…") { confirming = (.deleteAudioOnly, item) }.disabled(item.status.audio == .audioDeleted)
                            Button("Delete Meeting…", role: .destructive) { confirming = (.deleteMeeting, item) }
                        }
                }
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

struct MeetingRow: View {
    let item: MeetingListItem
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.headline).lineLimit(1)
            HStack {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(TranscriptRows.clock(SessionTime(nanoseconds: item.duration.nanoseconds))).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            AudioBadge(headline: item.status.audio).font(.caption)
            ProcessingBadge(headline: item.status.processing)
        }
        .padding(.vertical, 2)
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(hit.meetingTitle).font(.caption.bold())
                Spacer()
                Text(kind).font(.caption2).foregroundStyle(.secondary)
            }
            Text(highlighted).font(.callout).lineLimit(2)
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
            if bold { a.font = .callout.bold() }
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
                Label(waiting(reason), systemImage: "hourglass")
            case .running(let stage, let p): Label("\(Self.stageName(stage)) \(Int(p * 100))%", systemImage: "gearshape.2")
            case .complete: Label("Processed", systemImage: "doc.text")
            case .failed(let stage, _):
                Label("\(Self.stageName(stage)) failed — retry available", systemImage: "xmark.octagon").foregroundStyle(.red)
            case .cancelled(let stage): Label("\(Self.stageName(stage)) stopped", systemImage: "stop.circle")
            }
        }
        .font(.caption)
    }

    func waiting(_ r: SuspensionReason?) -> String {
        switch r {
        case .recordingActive: "Queued · paused while recording"
        case .thermalPressure: "Queued · paused while the Mac is hot"
        case .memoryPressure: "Queued · paused while memory is low"
        case .captureFault: "Queued · paused to protect the recording"
        case .userPaused: "Paused"
        case nil: "Queued"
        }
    }

    static func stageName(_ s: ProcessingStage) -> String {
        switch s {
        case .prepare: "Preparing audio"
        case .transcribe: "Transcribing"
        case .diarize: "Finding speakers"
        case .reconcile: "Matching speakers"
        case .notes: "Writing notes"
        case .live: "Live text"
        }
    }
}
