import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Domain
import Presentation
import Storage
import Export

/// Export action published by the open meeting (nil when it has no transcript), for the menu's ⌘E.
struct ExportAction { let run: () -> Void }

extension FocusedValues {
    @Entry var exportMarkdown: ExportAction?
}

/// T29: menu-bar commands for the meeting screen. Each shortcut is registered once, here or on its control: ⌘D lives on
/// View ▸ Show Details (T79; the meeting ⋯ menu shows the same toggle without registering it again); ⌘⇧R/P/S live on
/// the recorder buttons.
struct MeetingCommands: Commands {
    let library: LibraryModel
    @FocusedValue(\.exportMarkdown) private var exportMarkdown
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    /// Menu shortcuts must not act behind a sheet (rename, correct text, model setup, onboarding).
    var sheetOpen: Bool { NSApp.windows.contains { $0.attachedSheet != nil } }

    var body: some Commands {
        CommandMenu("Meeting") {
            ForEach(Array(LibraryModel.DetailTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button(tab.rawValue) { if !sheetOpen { library.detailTab = tab } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(library.detail == nil)
            }
            Divider()
            Button("Export Markdown…") { if !sheetOpen { exportMarkdown?.run() } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportMarkdown == nil)
            Divider()
            Button("Ask Anything…") { if !sheetOpen { library.askAllMeetings() } }   // T52: all meetings
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Details", isOn: $showDetails)   // the one place ⌘D is registered (T79)
                .keyboardShortcut("d", modifiers: .command)
            // T44: the toolbar sun/moon button does the same; ⌘⇧L is registered only here so it works in every window.
            Button(AppAppearance.toggleMenuTitle(effectiveIsDark: appearance == AppAppearance.dark.rawValue || (appearance == AppAppearance.system.rawValue && AppAppearance.effectiveIsDark))) {
                appearance = AppAppearance.toggled(effectiveIsDark: AppAppearance.effectiveIsDark).rawValue
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// The one menu of meeting actions (T79): the header's ⋯ and the meeting card's right-click menu list exactly these, in
/// this order. Everything acts on `meeting`, open or not; Export loads a closed meeting's transcript when chosen.
struct MeetingActionsMenu: View {
    struct Target {
        var id: MeetingID
        var title: String
        var hasTranscript: Bool
        var audioDeleted: Bool
        /// Recorded audio exists to copy (no segments, or deleted audio: Original Audio… is disabled).
        var hasAudio: Bool
    }
    let meeting: Target
    @Environment(LibraryModel.self) private var library
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault

    var body: some View {
        Button("Rename…") { library.requestRename(meeting.id, title: meeting.title) }
        // Transcript formats need a transcript; Original Audio… only audio, so an unprocessed meeting can still export it.
        Menu("Export") {
            Group {
                Button("Markdown…") { library.export(.markdown, meeting.id) }
                Button("Plain Text…") { library.export(.text, meeting.id) }
                Button("JSON…") { library.export(.json, meeting.id) }
            }
            .disabled(!meeting.hasTranscript)
            Divider()
            Button("Original Audio…") { library.exportAudio(meeting.id) }.disabled(!meeting.hasAudio)
        }
        .disabled(!meeting.hasTranscript && !meeting.hasAudio)
        Toggle("Show Details", isOn: $showDetails)   // ⌘D: View ▸ Show Details
        Divider()
        Button("Delete Audio Only…") { library.requestDelete(.deleteAudioOnly, meeting.id, title: meeting.title) }.disabled(meeting.audioDeleted)
        Button("Delete Meeting…", role: .destructive) { library.requestDelete(.deleteMeeting, meeting.id, title: meeting.title) }
    }
}

extension MeetingActionsMenu.Target {
    init(_ d: MeetingDetail) {
        self.init(id: d.meeting.id, title: d.meeting.title, hasTranscript: d.transcript != nil,
                  audioDeleted: d.meeting.audio == .deletedByUser, hasAudio: d.playbackUnavailableReason == nil)
    }
    init(_ item: MeetingListItem) {
        let audio = item.status.audio
        self.init(id: item.id, title: item.title, hasTranscript: item.hasTranscript, audioDeleted: audio == .audioDeleted,
                  hasAudio: audio != .audioDeleted && audio != .notStarted)
    }
}

/// Save panels for the meeting exports (moved from the header in T79 so the shared menu can export any meeting).
enum MeetingExport {
    enum Format { case markdown, text, json }

    @MainActor static func run(_ f: Format, _ detail: MeetingDetail) {
        guard let t = detail.displayTranscript else { return }
        let input = ExportInput(meeting: detail.meeting, transcript: t, summary: detail.summary, userNotes: detail.userNotes, scratchpad: detail.scratchpad)
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

    @MainActor static func exportAudio(_ detail: MeetingDetail, store: MeetingStore) {
        if let reason = detail.playbackUnavailableReason {
            let alert = NSAlert(); alert.messageText = "No audio to export"; alert.informativeText = reason; alert.runModal(); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Audio Here"
        panel.message = "Copies the original audio segments with a manifest of their times and any gaps."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            _ = try Exporter.exportAudio(meetingDirectory: store.meetingDirectory(detail.meeting.id), meetingID: detail.meeting.id,
                                         segments: detail.segments, events: detail.events,
                                         to: dir.appending(path: detail.meeting.title.replacingOccurrences(of: "/", with: "-") + " audio"))
        } catch { NSAlert(error: error).runModal() }
    }
}
