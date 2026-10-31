import SwiftUI
import AppKit
import Domain
import Presentation

/// The meeting's notes (spec 0008): one editable document. Generated sections look as they did (an eyebrow per section,
/// decisions on the sage edge, next steps with their owner and date, Limitations collapsed); every line can be edited,
/// and lines the user writes anywhere are kept through regeneration. A trailing empty line is always there to type into.
struct NotesPane: View {
    let detail: MeetingDetail
    let notesModelInstalled: Bool
    let showTranscript: () -> Void
    @Environment(LibraryModel.self) private var library
    @State private var draft: NotesDraft?
    @State private var saves = DebouncedSaves()
    @State private var confirmRegenerate = false
    @State private var versions: [NotesDocumentRevision] = []
    @FocusState private var focused: NoteBlockID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.double + 4) {
                stateBanner
                if let draft, NotesEditing.needsHeader(draft.blocks) {
                    VStack(alignment: .leading, spacing: AppStyle.grid) {
                        Eyebrow(text: NoteSection.overview.title)
                        if NotesEditing.isEmpty(draft.blocks) {
                            Text(NotesEditing.emptyInvitation).appFont(.callout).italic().foregroundStyle(Color.brandSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let draft {
                    NotesDocumentEditor(draft: Binding(get: { draft }, set: { self.draft = $0; scheduleSave() }), detail: detail,
                                        focused: $focused, jump: jump)
                }
            }
            .appFont(.body)
            .foregroundStyle(Color.brandText)
            .padding(.horizontal, AppStyle.double + 8).padding(.vertical, AppStyle.double + 4)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        .onChange(of: detail.meeting.id) { _, _ in flushPendingSave(); load() }
        // Notes written elsewhere (generation published, Replace, a restore) replace the draft unless the user is typing:
        // then their save is based on the older notes and the new ones show as pending instead of being overwritten.
        .onChange(of: detail.notes?.id) { _, id in
            if id != draft?.base?.id, draft?.isDirty != true { load() }
        }
        .onDisappear { flushPendingSave() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushPendingSave() }
        .confirmationDialog(NotesEditing.regenerateQuestion, isPresented: $confirmRegenerate) {
            Button("Regenerate") { regenerate() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(NotesEditing.regenerateExplanation) }
    }

    func load() {
        draft = NotesDraft(meetingID: detail.meeting.id, base: detail.notes)
    }

    func scheduleSave() {
        guard let d = draft, d.isDirty else { saves.cancel("notes"); return }
        saves.schedule("notes") { now in
            if let saved = library.saveNotes(d, immediately: now), draft?.meetingID == saved.meetingID { draft?.didSave(saved) }
        }
    }

    /// Writes the pending save synchronously (meeting switch, closing, quitting) so typed text is never lost.
    func flushPendingSave() { saves.flush() }

    /// Spec 0008 §5: asks first when the notes have the user's edits since they were generated. Generating the first
    /// notes never asks: there is nothing generated to replace, and the user's lines are kept.
    func requestRegenerate() {
        flushPendingSave()
        let generated = detail.summary != nil
        if generated, NotesEditing.regenerateNeedsConfirmation(draft?.base) { confirmRegenerate = true } else { regenerate() }
    }

    /// Generate (no generated notes yet) or Regenerate, with a sparkle: the notes model writes these.
    func generateButton(_ state: MeetingDetail.NotesState) -> some View {
        Button { requestRegenerate() } label: { Label(NotesEditing.generateTitle(state), systemImage: "sparkles") }
            .help(state == .none ? "Generate notes from the transcript on this Mac. Lines you wrote are kept"
                  : "Generate these notes again from the transcript. Lines you wrote are kept")
    }

    func regenerate() {
        flushPendingSave()
        library.regenerateNotes(detail.meeting.id)
    }

    @ViewBuilder var stateBanner: some View {
        if detail.pendingNotes != nil {
            banner("New notes are ready. Replace?", "sparkles", .statusAttention) {
                HStack {
                    Button("Dismiss") { library.dismissPendingNotes(detail.meeting.id) }
                        .help("Keep these notes as they are")
                    Button("Replace") { flushPendingSave(); library.replaceWithPendingNotes(detail.meeting.id) }
                        .help("Use the new notes. Lines you wrote are kept, and this version stays in Previous Versions")
                }
            }
        }
        let state = detail.notesState(notesModelInstalled: notesModelInstalled)
        switch state {
        case .none:
            EmptyView()   // the Generate button and the empty-notes invitation say it
        case .waiting(let why):
            banner(why, "hourglass", .brandSecondary) { EmptyView() }
        case .generating(let p):
            banner("Generating notes on this Mac… \(Int(p * 100))%", "gearshape.2", .brandSecondary) { ProgressView(value: p).frame(width: 120) }
        case .failed(let code):
            banner("Notes could not be generated (\(code)). The transcript is unaffected.", "xmark.octagon", .statusFailed) {
                Button("Try Again") { requestRegenerate() }
            }
        case .unavailable(let why):
            banner(why, "info.circle", .brandSecondary) { EmptyView() }
        case .ready(let stale, let failure):
            if stale {
                banner("The transcript or speakers changed after these notes were made.", "exclamationmark.arrow.circlepath", .statusAttention) {
                    generateButton(state)
                }
            } else if let failure {
                banner("Regenerating failed (\(failure)); these are the previous notes.", "exclamationmark.triangle", .statusAttention) {
                    Button("Try Again") { requestRegenerate() }
                }
            }
        }
        let offersGenerate = detail.pendingNotes == nil && [.none, .ready(stale: false, regenerationError: nil)].contains(state)
        let unavailable = if case .unavailable = state { true } else { false }
        if detail.notes != nil || offersGenerate || unavailable {
            HStack(spacing: AppStyle.grid) {
                Spacer()
                if detail.notes != nil { versionsMenu }
                if offersGenerate || unavailable {
                    generateButton(state).controlSize(.small).disabled(unavailable || !notesModelInstalled)
                }
            }
        }
    }

    /// Recent revisions by time; choosing one restores a copy of it as the newest revision.
    var versionsMenu: some View {
        Menu {
            ForEach(versions.dropFirst()) { r in
                Button(NotesEditing.versionLabel(r)) { flushPendingSave(); library.restoreNotes(r) }
            }
            if versions.count < 2 { Text("No earlier versions") }
        } label: {
            Label("Previous Versions", systemImage: "clock.arrow.circlepath")
        }
        .menuStyle(.button).controlSize(.small).fixedSize()
        .onAppear { versions = library.notesRevisions(detail.meeting.id) }
        .onChange(of: detail.notes?.id) { _, _ in versions = library.notesRevisions(detail.meeting.id) }
        .help("Restore an earlier version of these notes")
    }

    /// One line, no box (T45): icon and text in the state's colour, a small button on the right. The text stays; failed
    /// notes are a safety-relevant state.
    func banner<A: View>(_ text: String, _ icon: String, _ color: Color, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: AppStyle.grid) {
            Label(text, systemImage: icon).appFont(.callout).foregroundStyle(color)
            Spacer()
            action().controlSize(.small)
        }
        .padding(.vertical, AppStyle.half)
    }

    func jump(_ e: TranscriptEvidence) {
        guard let t = detail.transcript, let row = TranscriptRows.row(for: e, in: detail.rows, revision: t) else { return }
        library.focusRowID = row.id
        showTranscript()
    }
}

/// The notes document as editable lines. Return adds a line after the current one; Delete on an empty line removes it.
/// In a line you write, "# " starts a heading and "- " a bullet.
struct NotesDocumentEditor: View {
    @Binding var draft: NotesDraft
    let detail: MeetingDetail
    var focused: FocusState<NoteBlockID?>.Binding
    let jump: (TranscriptEvidence) -> Void
    @State private var limitationsExpanded = false

    var body: some View {
        let blocks = draft.blocks
        let sections = NotesEditing.sections(blocks)
        VStack(alignment: .leading, spacing: AppStyle.grid + 4) {
            ForEach(blocks) { block in
                let section = sections[block.id]
                if section == .limitations && !limitationsExpanded && !block.isUser {
                    EmptyView()
                } else if let s = block.section {
                    heading(block, s)
                } else {
                    NoteLineRow(block: block, section: section, detail: detail, focused: focused,
                                setText: { draft.setText(block.id, $0) }, setDetail: { draft.setDetail(block.id, $0) },
                                submit: { focused.wrappedValue = draft.insertLine(after: block.id) },
                                deleteEmpty: {
                                    // The cursor goes to the line above, unless that line is hidden (collapsed Limitations).
                                    let above = draft.remove(block.id)
                                    let hidden = above.map { a in sections[a] == .limitations && !limitationsExpanded && draft.block(a)?.isUser == false } ?? true
                                    focused.wrappedValue = hidden ? nil : above
                                },
                                removeLine: { _ = draft.remove(block.id) },
                                removeEvidence: { draft.removeEvidence($0, from: block.id) }, jump: jump)
                }
            }
        }
    }

    @ViewBuilder func heading(_ block: NoteBlock, _ s: NoteSection) -> some View {
        let n = NotesEditing.itemCount(after: block.id, in: draft.blocks)
        switch s {
        case .limitations:
            Button { limitationsExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").appFont(.caption, weight: .bold).rotationEffect(.degrees(limitationsExpanded ? 90 : 0))
                    Label("Limitations (\(n))", systemImage: "info.circle").appFont(.callout, weight: .medium)
                }
                .foregroundStyle(Color.brandSecondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, AppStyle.grid)
            .help("What the notes model could not confirm from the transcript")
            .accessibilityValue(limitationsExpanded ? "Expanded" : "Collapsed")
        case .overview:
            Eyebrow(text: block.text)
        default:
            Eyebrow(text: block.text, detail: n == 0 ? nil : n == 1 ? "1 item" : "\(n) items").padding(.top, AppStyle.grid)
        }
    }
}

struct NoteLineRow: View {
    let block: NoteBlock
    let section: NoteSection?
    let detail: MeetingDetail
    var focused: FocusState<NoteBlockID?>.Binding
    let setText: (String) -> Void
    let setDetail: (String) -> Void
    let submit: () -> Void
    let deleteEmpty: () -> Void
    let removeLine: () -> Void
    let removeEvidence: (EvidenceRef) -> Void
    let jump: (TranscriptEvidence) -> Void
    @Environment(\.showDetails) private var showDetails
    @Environment(\.textScale) private var scale

    var transcriptEvidence: [TranscriptEvidence] {
        block.evidence.compactMap { if case .transcript(let e) = $0 { e } else { nil } }
    }
    var muted: Bool { section == .limitations && !block.isUser }

    var body: some View {
        let row = VStack(alignment: .leading, spacing: AppStyle.half) {
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.grid) {
                if block.kind == .bullet { Text("•").foregroundStyle(Color.brandSecondary).accessibilityHidden(true) }
                TextField(placeholder, text: Binding(get: { block.text }, set: setText), axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(muted ? .callout : .body, weight: block.kind == .heading ? .semibold : .regular)
                    .foregroundStyle(muted ? Color.brandSecondary : Color.brandText)
                    .lineSpacing(AppStyle.readingLineSpacing(scale) * 0.6)
                    .focused(focused, equals: block.id)
                    .onSubmit(submit)
                    .onKeyPress(.delete) {
                        guard block.text.isEmpty else { return .ignored }
                        deleteEmpty()
                        return .handled
                    }
                    .accessibilityLabel(block.isUser ? "Your note" : "Note")
                if block.isUncertain {
                    Image(systemName: "questionmark.circle").font(.system(size: AppStyle.icon * scale)).foregroundStyle(Color.statusAttention)
                        .help("Not fully confirmed by the transcript — check the cited passage").accessibilityLabel("Not fully confirmed by the transcript")
                }
            }
            if let d = block.detail {
                // Missing data is said, never filled in; the line is editable like the text.
                TextField("Owner · date", text: Binding(get: { d }, set: setDetail))
                    .textFieldStyle(.plain).appFont(.caption).foregroundStyle(Color.brandSecondary)
                    .padding(.leading, block.kind == .bullet ? AppStyle.double : 0)
            }
            // Evidence is attribution, shown only with Details on; the uncertain marker above is a warning and always shows.
            if showDetails, !block.evidence.isEmpty {
                HStack(spacing: AppStyle.grid + 2) {
                    ForEach(Array(block.evidence.enumerated()), id: \.offset) { _, ref in
                        chip(ref).contextMenu { Button("Remove Source") { removeEvidence(ref) } }
                    }
                }
                .padding(.leading, block.kind == .bullet ? AppStyle.double : 0)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // A quiet way back to the source in both modes.
            let refs = transcriptEvidence
            if refs.count == 1 { Button("Show in Transcript") { jump(refs[0]) } }
            else { ForEach(Array(refs.enumerated()), id: \.offset) { _, e in Button("Show in Transcript at \(time(e))") { jump(e) } } }
            if !block.text.isEmpty { Divider(); Button("Remove Line", role: .destructive) { removeLine() } }
        }
        if section == .decisions {
            row.padding(.vertical, AppStyle.grid).padding(.leading, AppStyle.double)
                .overlay(alignment: .leading) { Rectangle().fill(Color.sage).frame(width: 3) }
        } else {
            row
        }
    }

    var placeholder: String { block.text.isEmpty && block.isUser ? "Write a note…" : "" }

    @ViewBuilder func chip(_ ref: EvidenceRef) -> some View {
        switch ref {
        case .transcript(let e):
            Button(time(e)) { jump(e) }.buttonStyle(SourceLinkStyle()).help("Show in transcript")
                .accessibilityLabel("Source at \(time(e))")
        case .userNote, .personalNote:
            Label("your note", systemImage: "square.and.pencil").appFont(.caption).foregroundStyle(Color.brandSecondary)
        }
    }

    func time(_ e: TranscriptEvidence) -> String {
        guard let seg = detail.transcript?.segment(e.segmentID), let w = seg.words.first(where: { $0.id == e.firstWord }) else { return "?" }
        return TranscriptRows.clock(w.interval.start)
    }
}
