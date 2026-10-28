import SwiftUI
import Domain
import Presentation
import Storage

struct MainView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RecorderModel.self) private var recorder
    @Environment(PlaybackModel.self) private var playback
    @State private var newTitle = ""
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault
    /// The Ask pane on the right (Inner Circle handoff); ⌘K opens it.
    @AppStorage("askPaneShown") private var askShown = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar()
                .toolbar(removing: .sidebarToggle)
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
            .toolbar { ToolbarItem(placement: .navigation) { RecordToolbarControl(model: recorder).fixedSize() }.sharedBackgroundVisibility(.hidden) }
            .inspector(isPresented: $askShown) {
                AskPane()
                    .inspectorColumnWidth(min: 230, ideal: 250, max: 380)
                    .fillsOfferedSpace()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { askShown.toggle() } label: { Label(askShown ? "Hide Ask" : "Show Ask", systemImage: "sidebar.trailing") }
                                .help(askShown ? "Hide the Ask pane" : "Ask about your meetings (⌘K)")
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            }
        }
        .foregroundStyle(Color.brandText, Color.brandSecondary, Color.controlBorder)
        .environment(\.showDetails, showDetails)
        .onChange(of: library.askFocusRequest) { _, _ in askShown = true }
        // T75: no window title (the menu bar names the app), no glass capsules behind the items, and the toolbar drawn in
        // Canvas like the sidebar, in both appearances.
        .toolbar(removing: .title)
        .toolbarBackground(Color.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .canvasTitleBar()
        .toolbar {
            // The system sidebar toggle, with a list icon (T75). View ▸ Show/Hide Sidebar keeps ⌃⌘S.
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                } label: {
                    Label(columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "list.bullet")
                }
                .help(columns == .detailOnly ? "Show the meeting list (⌃⌘S)" : "Hide the meeting list (⌃⌘S)")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { AppearanceToggle(compact: true) }.sharedBackgroundVisibility(.hidden)
        }
        // The shared meeting menu's Rename… and delete confirmations (T79), for the open meeting or any card.
        .sheet(isPresented: Binding(get: { library.renameRequest != nil }, set: { if !$0 { library.actionRequest = nil } })) {
            if let r = library.renameRequest {
                EditTextSheet(title: "Rename Meeting", text: $newTitle, help: "Shown in the meeting list, the meeting header, search and exports.") {
                    library.rename(r.meetingID, to: newTitle)
                }
                .onAppear { newTitle = r.title }
            }
        }
        .confirmationDialog(library.deleteRequest.map { $0.action.confirmationTitle($0.request.title) } ?? "",
                            isPresented: Binding(get: { library.deleteRequest != nil }, set: { if !$0 { library.actionRequest = nil } }),
                            titleVisibility: .visible, presenting: library.deleteRequest) { d in
            Button(d.action.buttonTitle, role: .destructive) {
                if d.request.meetingID == library.selection { playback.stop() }
                library.delete(d.action, d.request.meetingID)
            }
            Button("Cancel", role: .cancel) {}
        } message: { d in
            Text(d.action.explanation(library.store?.diskUsage(d.request.meetingID) ?? .init(originalAudioBytes: 0, derivedBytes: 0)))
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
    @Environment(ModelSetupModel.self) private var models
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
                            .contextMenu { MeetingActionsMenu(meeting: .init(item)) }   // the header's ⋯ menu too (T79)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { LocalModelFooter(state: .init(models.status)) }
        .background(Color.canvas)
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

/// The sidebar's footer (T77). Models ready: the quiet leaf and "Processing on this Mac". No local model: a warning and
/// "No local model found". Either way a click opens Settings on the Models tab, the only home of model setup.
struct LocalModelFooter: View {
    enum Kind: Equatable {
        case ready, installing, missing
        init(_ status: ModelSetupModel.Status) {
            switch status {
            case .ready, .checking: self = .ready   // checking takes milliseconds at launch: no warning flash
            case .installing: self = .installing
            case .recordOnly, .failed: self = .missing
            }
        }
    }
    let state: Kind
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings(.models) } label: {
            Group {
                switch state {
                case .ready: Label("Processing on this Mac", systemImage: "leaf").foregroundStyle(Color.statusOK)
                case .installing: Label("Installing local model…", systemImage: "arrow.down.circle").foregroundStyle(Color.brandSecondary)
                case .missing: Label("No local model found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.statusAttention)
                }
            }
            .appFont(.caption2, weight: state == .missing ? .medium : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppStyle.double).padding(.vertical, AppStyle.grid + 2)
        .help(help)
        .accessibilityHint("Opens Settings on the Models tab")
    }

    var help: String {
        switch state {
        case .ready: "Recording, transcription, notes and answers run on this Mac. Nothing is uploaded. Click for model details."
        case .installing: "The local model pack is installing. Click to see progress."
        case .missing: "Transcripts and notes need the local model pack. Amaranth still records. Click to install it in Settings → Models."
        }
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
