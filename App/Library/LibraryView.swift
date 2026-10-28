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
    /// The Ask pane on the right (Inner Circle handoff); ⌘K opens it.
    @AppStorage("askPaneShown") private var askShown = true

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            Group {
                if recorder.inSession, library.selection == nil || library.selection == recorder.meetingID {
                    LiveTranscriptView()
                } else if let d = library.detail {
                    MeetingDetailView(detail: d)
                } else if library.selection != nil {
                    Color.clear   // the selected meeting is loading (a few ms): blank, not "No meeting selected"
                } else {
                    ContentUnavailableView {
                        Label { Text("No meeting selected").appFont(.title) } icon: { BrandMark(size: 44) }
                    } description: {
                        Text("Press Record to capture a meeting. Audio stays on this Mac.").foregroundStyle(Color.brandSecondary)
                    }
                }
            }
            // Inside the measured area (T67): its wrapping text, measured at a near-zero width, otherwise became the split
            // view's minimum height, taller than the window, pushing both columns' tops off screen after Stop.
            .safeAreaInset(edge: .top, spacing: 0) { RecorderBanner(model: recorder) }
            // Content starts at the top and grows down; it never floats in the middle or bottom of the column. It never
            // sets the window's height either: the panes scroll inside whatever height the window has.
            .fillsOfferedSpace()
            .background(Color.surface)
            // In the detail column's toolbar, not over the sidebar: with the sidebar open the sidebar's toolbar area is too
            // narrow for the recording strip, and AppKit moved Stop into the overflow menu.
            .toolbar { ToolbarItem(placement: .navigation) { RecordToolbarControl(model: recorder).fixedSize() } }
            .inspector(isPresented: $askShown) {
                AskPane()
                    .inspectorColumnWidth(min: 230, ideal: 250, max: 380)
                    .fillsOfferedSpace()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { askShown.toggle() } label: { Label(askShown ? "Hide Ask" : "Show Ask", systemImage: "sidebar.trailing") }
                                .help(askShown ? "Hide the Ask pane" : "Ask about your meetings (⌘K)")
                        }
                    }
            }
        }
        .foregroundStyle(Color.brandText, Color.brandSecondary, Color.controlBorder)
        .environment(\.showDetails, showDetails)
        .onChange(of: library.askFocusRequest) { _, _ in askShown = true }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showingModels = true } label: {
                    if case .ready = models.status { Label("Models ready", systemImage: "checkmark.seal") }
                    else if case .installing = models.status { Label("Installing models…", systemImage: "arrow.down.circle") }
                    else { Label("Record-only — install models", systemImage: "arrow.down.circle") }
                }
                .help("Local speech and notes models")
            }
            ToolbarItem(placement: .primaryAction) { AppearanceToggle() }
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

/// The meeting library (Inner Circle handoff): canvas background, meetings grouped by day, the selected row on the
/// Selection colour with an accent edge. Rows are buttons in a focusable list rather than a `List`, whose key-window
/// highlight is a full accent fill (white on blush in dark mode); ↑/↓ move the selection while the list has focus, and
/// each row reports the selected trait. ↑/↓ move the selection, Home/End jump to the ends.
struct LibrarySidebar: View {
    @Environment(LibraryModel.self) private var library
    @State private var confirming: (DestructiveAction, MeetingListItem)?
    @State private var renaming: MeetingListItem?
    @State private var newTitle = ""
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var library = library
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {   // at most 500 rows (MeetingListItem.load); lazy stacks lay out nothing offscreen
                    Text("Your meetings").appFont(.headline).foregroundStyle(Color.brandText)
                        .padding(.horizontal, AppStyle.grid + 4).padding(.top, AppStyle.half).padding(.bottom, AppStyle.grid)
                        .accessibilityAddTraits(.isHeader)
                    if library.items.isEmpty {
                        Text("No recordings yet.").appFont(.callout).foregroundStyle(Color.brandSecondary).padding(.horizontal, AppStyle.grid + 4)
                    }
                    ForEach(LibrarySections.grouped(library.items, date: \.createdAt)) { section in
                        Eyebrow(text: section.title)
                            .padding(.horizontal, AppStyle.grid + 4).padding(.top, AppStyle.double).padding(.bottom, AppStyle.half)
                        ForEach(section.items) { item in
                            Button { library.selection = item.id; focused = true } label: {
                                MeetingRow(item: item, selected: library.selection == item.id, focused: focused)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .accessibilityAddTraits(library.selection == item.id ? [.isSelected] : [])
                            .contextMenu {
                                Button("Rename…") { newTitle = item.title; renaming = item }
                                Divider()
                                Button("Delete Audio Only…") { confirming = (.deleteAudioOnly, item) }.disabled(item.status.audio == .audioDeleted)
                                Button("Delete Meeting…", role: .destructive) { confirming = (.deleteMeeting, item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, AppStyle.grid).padding(.vertical, AppStyle.grid)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.home) { move(-library.items.count, proxy) }
            .onKeyPress(.end) { move(library.items.count, proxy) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Meetings")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // True of every meeting: capture, transcription, notes and answers all run on this Mac.
            Label("Processing on this Mac", systemImage: "leaf").appFont(.caption2).foregroundStyle(Color.statusOK)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppStyle.double).padding(.vertical, AppStyle.grid + 2)
                .help("Recording, transcription, notes and answers run on this Mac. Nothing is uploaded.")
        }
        .background(Color.canvas)
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

    func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = library.items.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let i = library.selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        library.selection = ids[i]
        proxy.scrollTo(ids[i])
        return .handled
    }
}

/// Meeting row: title with one status glyph, and "9:30 AM · 24 min" beneath (the day is the section heading). Selected:
/// the Selection colour with an accent edge, metadata in the text colour (secondary text is under 4.5:1 there).
struct MeetingRow: View {
    let item: MeetingListItem
    var selected = false
    /// The list has keyboard focus: the selected row also gets an accent outline, the visible focus.
    var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title).appFont(.callout, weight: .medium).lineLimit(2).truncationMode(.tail)
                    .foregroundStyle(Color.brandText)
                Spacer(minLength: 4)
                MeetingStatusGlyph(status: item.status)
            }
            Text(item.createdAt.formatted(date: .omitted, time: .shortened) + " · " + LibrarySections.duration(seconds: item.duration.seconds))
                .appFont(.caption, monospacedDigit: true).foregroundStyle(selected ? Color.brandText : Color.brandSecondary)
        }
        .padding(.leading, AppStyle.grid + 2).padding(.trailing, AppStyle.grid).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(Color.selection)
                    .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(Color.brandAccent).frame(width: 3) }
            }
        }
        .overlay { if selected && focused { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.brandAccent.opacity(0.7), lineWidth: 1) } }
        .contentShape(Rectangle())
        .help(item.title)
        .accessibilityElement(children: .combine)
    }
}

/// The single status glyph of a meeting; the tooltip is also its VoiceOver label.
struct MeetingStatusGlyph: View {
    let status: MeetingStatus
    /// Increased on the selected sidebar row (accent fill): coloured glyphs would vanish there, so use the row's text colour.
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        let g = MeetingStatusPresentation.glyph(status)
        Group {
            if g.spinner { ProgressView().controlSize(.small).scaleEffect(0.6) }
            else if let s = g.symbol {
                Image(systemName: s).foregroundStyle(prominence == .increased ? Color.brandText : color(g.tone))
            }
        }
        .frame(width: 16, height: 16)
        .help(g.tooltip)
        .accessibilityElement()
        .accessibilityLabel(g.tooltip)
    }

    func color(_ t: MeetingStatusPresentation.Tone) -> Color {
        Color.status(t)
    }
}

struct AudioBadge: View {
    let headline: MeetingStatus.AudioHeadline
    var body: some View {
        switch headline {
        case .saved: Label("Audio saved", systemImage: "checkmark.circle").foregroundStyle(Color.statusOK)
        case .savedWithGaps(let s): Label("Audio saved · \(Int(s.rounded())) s missing", systemImage: "exclamationmark.circle").foregroundStyle(Color.statusAttention)
        case .recording: Label("Recording", systemImage: "record.circle").foregroundStyle(Color.statusFailed)
        case .paused: Label("Paused", systemImage: "pause.circle")
        case .saving: Label("Saving…", systemImage: "arrow.down.circle")
        case .interrupted: Label("Interrupted — audio up to the interruption is saved", systemImage: "bolt.horizontal.circle").foregroundStyle(Color.statusAttention)
        case .notStarted: Label("No audio", systemImage: "circle")
        case .audioDeleted: Label("Audio deleted", systemImage: "trash.circle").foregroundStyle(Color.brandSecondary)
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
                Label("\(Self.stageName(stage)) failed — retry available", systemImage: "xmark.octagon").foregroundStyle(Color.statusFailed)
            case .cancelled(let stage): Label("\(Self.stageName(stage)) stopped", systemImage: "stop.circle")
            }
        }
        .appFont(.caption)
    }

    static func stageName(_ s: ProcessingStage) -> String { MeetingStatusPresentation.stageName(s) }
}
