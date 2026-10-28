import SwiftUI
import Domain
import Presentation

struct MeetingDetailView: View {
    let detail: MeetingDetail
    @Environment(LibraryModel.self) private var library
    @Environment(PlaybackModel.self) private var playback
    @Environment(ModelSetupModel.self) private var models
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault

    var notesModelInstalled: Bool { if case .ready = models.status { true } else { false } }
    var audioIssues: Int { AudioDetails.issues(detail.events, recordedSources: Set(detail.segments.map(\.source))).count }

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            header
            UnderlineTabs(tabs: LibraryModel.DetailTab.allCases, selection: $library.detailTab, title: \.rawValue,
                          badge: { $0 == .recording && audioIssues > 0 ? "\(audioIssues == 1 ? "A moment" : "\(audioIssues) moments") in the audio need a closer look" : nil },
                          trailing: { $0 == .recording })
                .help("Notes (⌘1) · Transcript (⌘2) · Audio details (⌘3)")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppStyle.double + 8)
            Hairline()
            Group {
                switch library.detailTab {
                case .notes: NotesPane(detail: detail, notesModelInstalled: notesModelInstalled) { library.detailTab = .transcript }
                case .transcript: TranscriptPane(detail: detail)
                case .recording: RecordingDetailsPane(detail: detail) { library.requestDelete(.deleteAudioOnly, detail.meeting.id, title: detail.meeting.title) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Hairline()
            // At the bottom of the column on every tab: play, the position, a scrubber and the length.
            PlaybackBar(detail: detail, spaceShortcut: library.detailTab == .transcript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { loadPlayback() }
        .onChange(of: detail.meeting.id) { _, _ in loadPlayback() }
        .onChange(of: library.focusRowID) { _, id in if id != nil { library.detailTab = .transcript } }
        .focusedSceneValue(\.exportMarkdown, detail.transcript == nil ? nil : ExportAction { [library, id = detail.meeting.id] in library.export(.markdown, id) })
    }

    /// Eyebrow date and time, the meeting title in the display face, then people, length, calendar and status on one
    /// line (T50 chips, now understated: text with an underline for the editable ones).
    var header: some View {
        VStack(alignment: .leading, spacing: AppStyle.half + 2) {
            // T87: the ⋯ menu at the top-right corner, centred on the date line.
            HStack(alignment: .center) {
                Text(detail.meeting.createdAt.formatted(.dateTime.month(.wide).day().year().hour().minute()).replacingOccurrences(of: " at ", with: " · "))
                    .appFont(.eyebrow).foregroundStyle(Color.brandSecondary)
                    .help("Recorded \(detail.meeting.createdAt.formatted(date: .complete, time: .shortened))")
                Spacer(minLength: AppStyle.grid)
                actionsMenu
            }
            // Static: Rename… is in the ⋯ menu and the card's right-click menu (T26, T79).
            Text(detail.meeting.title).appFont(.display).lineLimit(2).foregroundStyle(Color.brandText).accessibilityAddTraits(.isHeader)
            HStack(spacing: AppStyle.double) {
                // Narrow windows drop the calendar chip's words, then a linked event's title, before anything truncates.
                ViewThatFits(in: .horizontal) {
                    headerChips(compact: false)
                    headerChips(compact: true)
                    headerChips(compact: true, eventTitle: false)
                }
                Text(TranscriptRows.clock(SessionTime(nanoseconds: detail.meeting.duration.nanoseconds))).monospacedDigit().foregroundStyle(Color.brandSecondary)
                    .accessibilityLabel("Length \(LibrarySections.duration(seconds: detail.meeting.duration.seconds))")
                // Quick review: one glyph (hover for its meaning); Details on: both full badges.
                if showDetails {
                    AudioBadge(headline: detail.status.audio)
                    ProcessingBadge(headline: detail.status.processing)
                } else {
                    MeetingStatusGlyph(status: detail.status)
                }
                Spacer()
                if case .failed = detail.status.processing { Button("Retry Processing") { library.retry(detail.meeting.id) }.buttonStyle(.brandOutline).help("Run the failed processing steps again") }
                if case .notQueued = detail.status.processing, detail.meeting.canPlayAudio { Button("Process") { library.process(detail.meeting.id) }.buttonStyle(.brandOutline).help("Transcribe, find speakers and write notes on this Mac") }
            }
            .appFont(.caption)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppStyle.double + 8).padding(.top, AppStyle.double + 4).padding(.bottom, AppStyle.grid + 2)
    }

    /// The meeting's ⋯ (T79): the same menu as the card's right-click menu, Export and Show Details included.
    var actionsMenu: some View {
        Menu { MeetingActionsMenu(meeting: .init(detail)) } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: AppStyle.iconLarge))
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Color.brandSecondary)
        .help("Rename, export, show details or delete")
        .accessibilityLabel("Meeting actions")
    }

    /// `eventTitle: false` is the narrowest variant: a linked event shows as its icon only (the tooltip names it).
    func headerChips(compact: Bool, eventTitle: Bool = true) -> some View {
        HStack(spacing: AppStyle.double) {
            PeopleChip(meeting: detail.meeting).id(detail.meeting.id)
            CalendarLinkChip(meeting: detail.meeting, compact: compact, iconOnly: !eventTitle).id(detail.meeting.id)
            FolderChip(meeting: detail.meeting, iconOnly: !eventTitle)
        }
        .fixedSize()
    }

    func loadPlayback() {
        playback.load(meetingDirectory: library.store!.meetingDirectory(detail.meeting.id), segments: detail.segments)
    }
}

/// One header chip (T50), in the handoff's quiet style: icon and text, no capsule. `.action` chips (people, calendar)
/// are underlined so they read as editable without relying on colour; `.inert` is for placeholders: dashed underline,
/// secondary text, so it never reads as a control.
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
            if !text.isEmpty {
                Text(text).lineLimit(1)
                    .underline(style == .action, color: hovering ? Color.brandAccent : Color.controlBorder)
            }
        }
        .appFont(.caption)
        .foregroundStyle(attention ? AnyShapeStyle(Color.statusAttention) : style == .action ? AnyShapeStyle(hovering ? Color.brandAccent : Color.brandText)
                         : AnyShapeStyle(Color.brandSecondary))
        .overlay(alignment: .bottom) {
            if style == .inert, !text.isEmpty { Line().stroke(Color.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1).offset(y: 1) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

/// The meeting's folder (T40, like the folder button in Granola's note header): its name, or just the folder icon when
/// unfiled; a click lists the folders to move it to.
struct FolderChip: View {
    let meeting: Meeting
    var iconOnly = false
    @Environment(LibraryModel.self) private var library
    @State private var hovering = false

    var body: some View {
        let name = library.folderName(meeting.folderID)
        Menu {
            MoveToFolderItems(meeting: meeting.id, folder: meeting.folderID)
            if name != nil { Button("Remove from Folder") { library.move(meeting.id, to: nil) } }
        } label: {
            HeaderChip(symbol: "folder", text: iconOnly ? "" : name ?? "", style: .action, hovering: hovering)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
        .help(name.map { "In the folder “\($0)” (click to move)" } ?? "Move to a folder")
        .accessibilityLabel(name.map { "Folder \($0)" } ?? "Not in a folder")
        .accessibilityHint("Move this meeting to a folder")
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
                    .appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
                    .help("Added from the linked event. Unlinking keeps them; delete any you don't want here.")
            }
            Text("Saved with this meeting and included in exports.").appFont(.caption).foregroundStyle(Color.brandSecondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(MeetingPeople.parse(text, keeping: people)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.brandProminent)
                    .help("Save (⌘↩)")
            }
        }
        .padding(12)
        .onAppear { focused = .names }
    }
}

/// Audio details (the "Recording" tab; Inner Circle handoff): a plain-language summary, one notice per stretch of
/// missing audio with a link to listen there, then sources, storage and retention, the raw recording events under a
/// disclosure (diagnostics are kept, never replaced by a guess), and a deliberate Delete audio… button.
struct RecordingDetailsPane: View {
    let detail: MeetingDetail
    var deleteAudio: () -> Void = {}
    @Environment(PlaybackModel.self) private var playback
    @AppStorage("audioEventsExpanded") private var eventsExpanded = false

    var sources: Set<SourceKind> { Set(detail.segments.map(\.source)) }

    var body: some View {
        let issues = AudioDetails.issues(detail.events, recordedSources: sources)
        let deleted = detail.meeting.audio != .present
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.double) {
                Eyebrow(text: "Recording")
                Text(AudioDetails.headline(issues: issues.count, audioDeleted: deleted)).appFont(.title, weight: .regular)
                    .foregroundStyle(Color.brandText).accessibilityAddTraits(.isHeader)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in IssueNotice(issue: issue, playable: detail.playbackUnavailableReason == nil) {
                    playback.play(from: max(0, issue.start.seconds - 3))
                } }
                VStack(spacing: 0) {
                    row("Audio sources", AudioDetails.sourcesLabel(sources))
                    row("Storage", ByteCountFormatter.string(fromByteCount: detail.diskUsage.totalBytes, countStyle: .file) + " · on this Mac")
                    row("Retention", deleted ? "Audio deleted; the transcript and notes are kept" : "Kept until you delete it")
                }
                VStack(alignment: .leading, spacing: AppStyle.grid) {
                    Button { eventsExpanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").appFont(.caption, weight: .bold).foregroundStyle(Color.brandSecondary)
                                .rotationEffect(.degrees(eventsExpanded ? 90 : 0))
                            Text("Recording events").appFont(.callout)
                            Text(detail.events.count == 1 ? "1 event" : "\(detail.events.count) events").appFont(.caption).foregroundStyle(Color.brandSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(eventsExpanded ? "Expanded" : "Collapsed")
                    if eventsExpanded { events.padding(.leading, AppStyle.double) }
                    Hairline()
                }
                if !deleted {
                    Button("Delete audio…", action: deleteAudio).buttonStyle(.brandDestructive)
                        .help("Delete the recorded audio. You choose in the next step; the transcript and notes are kept.")
                }
            }
            .padding(.horizontal, AppStyle.double + 8).padding(.vertical, AppStyle.double + 4)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(Color.brandSecondary)
                Spacer(minLength: AppStyle.double)
                Text(value).foregroundStyle(Color.brandText).multilineTextAlignment(.trailing)
            }
            .appFont(.callout)
            .padding(.vertical, AppStyle.grid + 4)
            Hairline()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var events: some View {
        VStack(alignment: .leading, spacing: AppStyle.half + 2) {
            if detail.events.isEmpty { Text("No interruptions, gaps or device changes.").foregroundStyle(Color.brandSecondary) }
            ForEach(detail.events) { e in
                HStack(alignment: .firstTextBaseline) {
                    Text(TranscriptRows.clock(e.interval.start)).monospacedDigit().frame(width: 64, alignment: .leading)
                    Text(Self.describe(e))
                    Spacer()
                    Text(e.source.map { $0 == .microphone ? "mic" : "system" } ?? "all").foregroundStyle(Color.brandSecondary)   // muted even on attention rows
                }
                .foregroundStyle(e.isMissingAudio ? Color.statusAttention : Color.brandText)
            }
        }
        .appFont(.caption)
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

/// One stretch of missing audio: a warning edge, what is missing in plain words, and where to listen.
struct IssueNotice: View {
    let issue: AudioDetails.Issue
    let playable: Bool
    let listen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            Label { Text(issue.title) } icon: { Image(systemName: "waveform.slash") }
                .appFont(.headline, weight: .medium).foregroundStyle(Color.statusAttention)
            Text(issue.body).appFont(.callout).foregroundStyle(Color.brandText).fixedSize(horizontal: false, vertical: true)
            if playable {
                Button("Listen around \(TranscriptRows.clock(issue.start))", action: listen).buttonStyle(SourceLinkStyle())
                    .help("Play from a few seconds before the gap")
            }
        }
        .padding(AppStyle.double)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas)
        .overlay(alignment: .leading) { Rectangle().fill(Color.statusAttention).frame(width: 3) }
        .accessibilityElement(children: .contain)
    }
}
