import SwiftUI
import Domain
import Presentation
import Storage

struct MainView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(RecorderModel.self) private var recorder
    @Environment(PlaybackModel.self) private var playback
    @State private var newTitle = ""
    @State private var folderName = ""
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault
    /// The Ask pane on the right (Inner Circle handoff); ⌘K opens it.
    @AppStorage("askPaneShown") private var askShown = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar()
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 320)   // T80: a little narrower
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
                    // T86: the window's top-right corner, open or closed: the sun/moon, then the Ask toggle (a speech bubble, so
                    // it reads as a chat pane rather than a second sidebar). Declared on the inspector so AppKit keeps them at
                    // the trailing edge, above the pane when it is open.
                    .toolbar {
                        ToolbarSpacer(.flexible)
                        ToolbarItemGroup(placement: .primaryAction) {
                            AppearanceToggle(compact: true)
                            Button { askShown.toggle() } label: { Label(askShown ? "Hide Ask" : "Show Ask", systemImage: "bubble.left") }
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
        // Folders (T40): New Folder… and Rename… share one name sheet; Delete Folder… says the meetings stay.
        .sheet(isPresented: Binding(get: { library.folderNameRequest != nil }, set: { if !$0 { library.folderRequest = nil } })) {
            switch library.folderNameRequest {
            case .create(let moving):
                EditTextSheet(title: "New Folder", text: $folderName,
                              help: moving == nil ? "Folders hold meetings for a client or a project. A meeting is in one folder at most."
                                                  : "The meeting moves into the new folder.") {
                    library.createFolder(named: folderName, moving: moving)
                }
                .onAppear { folderName = "" }
            case .rename(let f):
                EditTextSheet(title: "Rename Folder", text: $folderName, help: "Its meetings stay in it.") {
                    library.renameFolder(f.id, to: folderName)
                }
                .onAppear { folderName = f.name }
            default: EmptyView()
            }
        }
        .confirmationDialog(library.folderDeleteRequest.map { "Delete the folder “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { library.folderDeleteRequest != nil }, set: { if !$0 { library.folderRequest = nil } }),
                            titleVisibility: .visible, presenting: library.folderDeleteRequest) { f in
            Button("Delete Folder", role: .destructive) { library.deleteFolder(f.id) }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text(LibraryFolders.deleteMessage(count: library.meetingCount(in: f.id)))
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
                        .padding(.horizontal, AppStyle.grid + 2).padding(.top, AppStyle.half).padding(.bottom, AppStyle.half)
                        .accessibilityAddTraits(.isHeader)
                    FolderFilterList()
                    Hairline().padding(.horizontal, AppStyle.grid + 2).padding(.top, AppStyle.half)
                    if library.visibleItems.isEmpty {
                        Text(LibraryFolders.emptyMessage(library.folderFilter, libraryEmpty: library.items.isEmpty))
                            .appFont(.callout).foregroundStyle(Color.brandSecondary).padding(.horizontal, AppStyle.grid + 2).padding(.top, AppStyle.grid)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(LibrarySections.grouped(library.visibleItems, date: \.createdAt)) { section in
                        Eyebrow(text: section.title, color: .brandText)   // Text, not Secondary, over the Lower Garden
                            .padding(.horizontal, AppStyle.grid + 2).padding(.top, AppStyle.grid + 4).padding(.bottom, 2)
                        ForEach(section.items) { item in
                            Button { library.selection = item.id; focused = true } label: {
                                MeetingRow(item: item, selected: library.selection == item.id, focused: focused)
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .accessibilityAddTraits(library.selection == item.id ? [.isSelected] : [])
                            .contextMenu { MeetingActionsMenu(meeting: .init(item)) }   // the header's ⋯ menu too (T79)
                            // T41: drag a card onto a folder row (or All meetings to unfile it).
                            .draggable(DraggedMeeting(item.id)) {
                                MeetingRow(item: item, selected: true).frame(width: 180).background(Color.canvas)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppStyle.half + 2).padding(.vertical, AppStyle.grid)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            .onKeyPress(.home) { move(-library.visibleItems.count, proxy) }
            .onKeyPress(.end) { move(library.visibleItems.count, proxy) }
            .contextMenu { Button("New Folder…") { library.folderRequest = .create(moving: nil) } }   // the sidebar background
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Meetings")
        }
        // Opaque, so the Lower Garden stops behind the footer.
        .safeAreaInset(edge: .bottom, spacing: 0) { LocalModelFooter(state: .init(models.status)).background(Color.canvas) }
        // Lower Garden: once, behind the whole body (heading to footer), fixed while the rows scroll over it.
        .background { LowerGardenWatermark() }
        .background(Color.canvas)
    }

    func move(_ delta: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = library.visibleItems.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let i = library.selection.flatMap { ids.firstIndex(of: $0) }.map { min(max($0 + delta, 0), ids.count - 1) } ?? 0
        library.selection = ids[i]
        proxy.scrollTo(ids[i])
        return .handled
    }
}

/// The folder filter at the top of the sidebar (T40, Granola-style): “All meetings” and “Unsorted” (T83), then a Folders
/// heading with a `+` and one row per folder with its meeting count. Clicking a row filters the list below; a folder's right-click menu
/// renames or deletes it (its meetings stay).
struct FolderFilterList: View {
    @Environment(LibraryModel.self) private var library
    /// The row a meeting is dragged over (T41).
    @State private var dropTarget: String?

    var body: some View {
        let rows = library.folderRows
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows.prefix(2)) { r in row(r, icon: r.filter == .all ? "tray.full" : "tray") }
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Folders", color: .brandText)
                Spacer()
                Button { library.folderRequest = .create(moving: nil) } label: {
                    Image(systemName: "plus").font(.system(size: AppStyle.iconSmall, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.brandSecondary)
                .help("New Folder (⇧⌘N)")
                .accessibilityLabel("New Folder")
            }
            .padding(.leading, AppStyle.grid + 2).padding(.trailing, AppStyle.grid).padding(.top, AppStyle.grid).padding(.bottom, 2)
            ForEach(rows.dropFirst(2)) { r in
                row(r, icon: "folder")
                    .contextMenu {
                        if let f = library.folders.first(where: { $0.id == r.folderID }) {
                            Button("Rename…") { library.folderRequest = .rename(f) }
                            Button("Delete Folder…", role: .destructive) { library.folderRequest = .delete(f) }
                        }
                    }
            }
        }
    }

    func row(_ r: LibraryFolders.Row, icon: String) -> some View {
        let selected = library.folderFilter == r.filter
        return Button { library.folderFilter = r.filter } label: {
            FolderRowLabel(name: r.name, count: r.count, icon: icon, selected: selected, targeted: dropTarget == r.id)
        }
        .buttonStyle(.plain)
        // T41: meetings dropped here move into this folder; on All meetings or Unsorted they leave their folder. Drops that change
        // nothing (or name a folder deleted meanwhile) are refused quietly.
        .dropDestination(for: DraggedMeeting.self) { dropped, _ in
            let moves = LibraryFolders.dropMoves(dropped.map(\.meetingID), onto: r.folderID, items: library.items, folders: library.folders)
            for id in moves { library.move(id, to: r.folderID) }
            return !moves.isEmpty
        } isTargeted: { over in
            if over { dropTarget = r.id } else if dropTarget == r.id { dropTarget = nil }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue("\(r.count) meetings")
    }
}

/// One folder filter row: icon, name, count; the shown folder on the Selection colour like a selected card.
struct FolderRowLabel: View {
    let name: String
    let count: Int
    let icon: String
    var selected = false
    /// A meeting is dragged over the row (T41).
    var targeted = false

    var body: some View {
        HStack(spacing: AppStyle.half + 2) {
            Image(systemName: icon).font(.system(size: AppStyle.icon)).foregroundStyle(selected ? Color.brandAccent : Color.brandSecondary)
                .frame(width: 16)
            Text(name).appFont(.caption, weight: selected ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(Color.brandText)
            Spacer(minLength: 2)
            Text("\(count)").appFont(.caption2, monospacedDigit: true).foregroundStyle(selected ? Color.brandText : Color.brandSecondary)
        }
        .padding(.leading, AppStyle.grid + 2).padding(.trailing, AppStyle.grid).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if selected || targeted { RoundedRectangle(cornerRadius: 6).fill(Color.selection) } }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.brandAccent, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .help(name)
        .accessibilityElement(children: .combine)
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

/// Meeting row: the title, and "9:30 AM · 24 min" beneath (the day is the section heading). A glyph only while the
/// meeting is processing or when processing failed (T80); the header has the full status. Selected:
/// the Selection colour with an accent edge, metadata in Selected Metadata (secondary text is under 4.5:1 there).
/// Unselected: no backing; the Lower Garden shows behind the text (user choice 2026-10-28: the handoff's 92% Canvas
/// backing drew obtrusive card shapes over the garden, worst at narrow widths).
struct MeetingRow: View {
    let item: MeetingListItem
    var selected = false
    /// The list has keyboard focus: the selected row also gets an accent outline, the visible focus.
    var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title).appFont(.caption, weight: .medium).lineLimit(2).truncationMode(.tail)
                    .foregroundStyle(Color.brandText)
                Spacer(minLength: 2)
                if let glyph = MeetingStatusPresentation.cardGlyph(item.status) { MeetingStatusGlyph(glyph: glyph) }
            }
            Text(item.createdAt.formatted(date: .omitted, time: .shortened) + " · " + LibrarySections.duration(seconds: item.duration.seconds))
                // T85: 2 pt under caption2, quieter than the title: Secondary at 80%, or Selected Metadata on the selected card.
                .appFont(.cardMeta, monospacedDigit: true).foregroundStyle(selected ? Color.selectedMetadata : Color.brandSecondary.opacity(0.8))
        }
        .padding(.leading, AppStyle.grid + 2).padding(.trailing, AppStyle.half + 2).padding(.vertical, 5)
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
    let g: MeetingStatusPresentation.Glyph
    /// Increased on the selected sidebar row (accent fill): coloured glyphs would vanish there, so use the row's text colour.
    @Environment(\.backgroundProminence) private var prominence
    /// The header's full glyph for `status`.
    init(status: MeetingStatus) { g = MeetingStatusPresentation.glyph(status) }
    init(glyph: MeetingStatusPresentation.Glyph) { g = glyph }

    var body: some View {
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
