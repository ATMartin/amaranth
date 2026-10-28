import SwiftUI
import AppKit
import Domain
import Presentation

/// Generated notes with their evidence, the user's own notes (never overwritten by regeneration), and the private
/// scratchpad with its explicit "include when generating notes" switch. Both editors start collapsed (T24).
struct NotesPane: View {
    let detail: MeetingDetail
    let notesModelInstalled: Bool
    let showTranscript: () -> Void
    @Environment(LibraryModel.self) private var library
    @State private var userNotes = ""
    @State private var scratchpad = ""
    @State private var includeScratchpad = false
    @State private var saves = DebouncedSaves()
    @FocusState private var focusedEditor: Editor?
    enum Editor: Hashable { case notes, scratchpad }
    @AppStorage("notesUserNotesExpanded") private var userNotesExpanded = false
    @AppStorage("notesScratchpadExpanded") private var scratchpadExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppStyle.double + 4) {
                stateBanner
                if let s = detail.summary { generated(s) }
                // The user's own text, apart from the generated draft (handoff): same storage and privacy as before.
                Hairline().padding(.top, AppStyle.grid)
                CollapsibleEditor(title: "Your notes", systemImage: "square.and.pencil", hint: CollapsedEditorHint.text(for: userNotes),
                                  help: "Yours alone: regenerating notes never changes this text.", isExpanded: expansion($userNotesExpanded)) {
                    TextEditor(text: $userNotes).appFont(.body).frame(minHeight: 120)
                        .editableField(focused: $focusedEditor, as: .notes, isEmpty: userNotes.isEmpty, placeholder: "Write your own notes…")
                        .onChange(of: userNotes) { _, v in
                            let id = detail.meeting.id
                            saves.schedule("notes") { now in library.saveUserNotes(id, markdown: v, immediately: now) }
                        }
                }
                CollapsibleEditor(title: "Private scratchpad", systemImage: "lock",
                                  hint: CollapsedEditorHint.text(for: scratchpad).map { includeScratchpad ? $0 + " · used for notes" : $0 } ?? "Only for you",
                                  help: "Private: not exported or searched unless you choose to.", isExpanded: expansion($scratchpadExpanded)) {
                    VStack(alignment: .leading) {
                        TextEditor(text: $scratchpad).appFont(.body).frame(minHeight: 80)
                            .editableField(focused: $focusedEditor, as: .scratchpad, isEmpty: scratchpad.isEmpty, placeholder: "Private notes, only on this Mac…")
                            .onChange(of: scratchpad) { _, v in
                                let id = detail.meeting.id
                                // Read the switch when the save runs, not when typing happened (flipping it within the
                                // debounce window must not be reverted).
                                saves.schedule("scratchpad") { now in library.saveScratchpad(id, text: v, include: includeScratchpad, immediately: now) }
                            }
                        Toggle("Use these private notes when generating notes", isOn: $includeScratchpad)
                            .onChange(of: includeScratchpad) { _, v in
                                saves.cancel("scratchpad")   // this save includes the latest text
                                library.saveScratchpad(detail.meeting.id, text: scratchpad, include: v)
                            }
                        Text("Private: not exported or searched unless you choose to. Notes that used them are labelled.")
                            .appFont(.caption).foregroundStyle(Color.brandSecondary)
                    }
                }
            }
            .appFont(.body)
            .foregroundStyle(Color.brandText)
            .padding(.horizontal, AppStyle.double + 8).padding(.vertical, AppStyle.double + 4)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadEditors)
        .onChange(of: detail.meeting.id) { _, _ in flushPendingSave(); loadEditors() }
        .onDisappear { flushPendingSave() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flushPendingSave() }
    }

    func loadEditors() {
        userNotes = detail.userNotes?.markdown ?? ""
        scratchpad = detail.scratchpad?.text ?? ""
        includeScratchpad = detail.scratchpad?.includeInSummary ?? false
    }

    /// Writes pending saves synchronously (meeting switch, collapsing, closing, quitting) so typed text is never lost.
    func flushPendingSave() { saves.flush() }

    /// Collapsing an editor writes its debounced edit first.
    func expansion(_ stored: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { stored.wrappedValue }, set: { v in
            if !v { flushPendingSave() }
            stored.wrappedValue = v
        })
    }

    @ViewBuilder var stateBanner: some View {
        switch detail.notesState(notesModelInstalled: notesModelInstalled) {
        case .none:
            banner("No notes yet.", "doc.text", .brandSecondary) { Button("Generate Notes") { library.regenerateNotes(detail.meeting.id) } }
        case .waiting(let why):
            banner(why, "hourglass", .brandSecondary) { EmptyView() }
        case .generating(let p):
            banner("Generating notes on this Mac… \(Int(p * 100))%", "gearshape.2", .brandSecondary) { ProgressView(value: p).frame(width: 120) }
        case .failed(let code):
            banner("Notes could not be generated (\(code)). The transcript is unaffected.", "xmark.octagon", .statusFailed) {
                Button("Try Again") { library.regenerateNotes(detail.meeting.id) }
            }
        case .unavailable(let why):
            banner(why, "info.circle", .brandSecondary) { EmptyView() }
        case .ready(let stale, let failure):
            if stale {
                banner("The transcript or speakers changed after these notes were made.", "exclamationmark.arrow.circlepath", .statusAttention) {
                    Button("Regenerate") { library.regenerateNotes(detail.meeting.id) }
                }
            }
            if let failure {
                banner("Regenerating failed (\(failure)); these are the previous notes.", "exclamationmark.triangle", .statusAttention) {
                    Button("Try Again") { library.regenerateNotes(detail.meeting.id) }
                }
            }
        }
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

    /// The generated draft (handoff): an eyebrow that says it is a draft to check, the overview as a lede, decisions in
    /// sage-edged blocks, next steps with their owner and date (or that none was stated), open questions, and what the
    /// model could not establish (Limitations), each in its own section.
    @ViewBuilder func generated(_ s: SummaryRevision) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.half) {
            Eyebrow(text: "Meeting notes", detail: "Draft from this Mac · check it against the transcript")
            if s.influencedByPersonalNotes {
                Label("These notes also used your private scratchpad.", systemImage: "lock.doc").appFont(.caption).foregroundStyle(Color.brandSecondary)
            }
        }
        if !s.content.overview.isEmpty {
            VStack(alignment: .leading, spacing: AppStyle.grid + 2) {
                ForEach(Array(s.content.overview.enumerated()), id: \.element.id) { i, item in
                    NoteItemRow(item: item, detail: detail, jump: jump, role: i == 0 ? .title : .body)
                }
            }
        }
        if !s.content.decisions.isEmpty {
            section("Decisions", s.content.decisions.count) {
                ForEach(s.content.decisions) { item in
                    NoteItemRow(item: item, detail: detail, jump: jump)
                        .padding(.vertical, AppStyle.grid).padding(.leading, AppStyle.double)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.sage).frame(width: 3) }
                }
            }
        }
        if !s.content.actionItems.isEmpty {
            section("Next steps", s.content.actionItems.count) {
                ForEach(s.content.actionItems) { NoteItemRow(item: $0, detail: detail, jump: jump) }
            }
        }
        if !s.content.openQuestions.isEmpty {
            section("Still open", s.content.openQuestions.count) {
                ForEach(s.content.openQuestions) { NoteItemRow(item: $0, detail: detail, jump: jump) }
            }
        }
        if !s.content.limitations.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.content.limitations) { Text("• " + $0.text).appFont(.callout).foregroundStyle(Color.brandSecondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Limitations (\(s.content.limitations.count))", systemImage: "info.circle").appFont(.callout, weight: .medium)
                    .foregroundStyle(Color.brandSecondary)
            }
            .help("What the notes model could not confirm from the transcript")
        }
    }

    func section<C: View>(_ title: String, _ count: Int, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.grid + 4) {
            Eyebrow(text: title, detail: count == 1 ? "1 item" : "\(count) items")
            content()
        }
    }

    func jump(_ e: TranscriptEvidence) {
        guard let t = detail.transcript, let row = TranscriptRows.row(for: e, in: detail.rows, revision: t) else { return }
        library.focusRowID = row.id
        showTranscript()
    }
}

struct NoteItemRow: View {
    let item: SummaryItem
    let detail: MeetingDetail
    let jump: (TranscriptEvidence) -> Void
    /// `.title` for the overview's lede.
    var role: AppStyle.Role = .body
    @Environment(\.showDetails) private var showDetails
    @Environment(\.textScale) private var scale

    var transcriptEvidence: [TranscriptEvidence] {
        item.evidence.compactMap { if case .transcript(let e) = $0 { e } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.half) {
            HStack(alignment: .firstTextBaseline) {
                if let t = item.title { Text(t).appFont(.body, weight: .semibold) }
                Text(item.text).appFont(role, weight: role == .title ? .regular : nil).lineSpacing(AppStyle.readingLineSpacing(scale) * 0.6)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if item.uncertain {
                    Image(systemName: "questionmark.circle").font(.system(size: AppStyle.icon * scale)).foregroundStyle(Color.statusAttention)
                        .help("Not fully confirmed by the transcript — check the cited passage").accessibilityLabel("Not fully confirmed by the transcript")
                }
            }
            if item.kind == .actionItem || item.owner != nil || item.due != nil {
                // Missing data is said, never filled in.
                Text("\(item.owner ?? "No owner stated")  ·  \(item.due?.originalText ?? "no date stated")")
                    .appFont(.caption).foregroundStyle(Color.brandSecondary)
            }
            // Evidence is attribution, shown only with Details on; the uncertain marker above is a warning and always shows.
            if showDetails {
                HStack(spacing: AppStyle.grid + 2) {
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, ref in
                        switch ref {
                        case .transcript(let e):
                            Button(time(e)) { jump(e) }.buttonStyle(SourceLinkStyle()).help("Show in transcript")
                                .accessibilityLabel("Source at \(time(e))")
                        case .personalNote:
                            Label("your private note", systemImage: "lock").appFont(.caption).foregroundStyle(Color.brandSecondary)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // A quiet way back to the source in both modes.
            let refs = transcriptEvidence
            if refs.count == 1 { Button("Show in Transcript") { jump(refs[0]) } }
            else { ForEach(Array(refs.enumerated()), id: \.offset) { _, e in Button("Show in Transcript at \(time(e))") { jump(e) } } }
        }
    }

    func time(_ e: TranscriptEvidence) -> String {
        guard let seg = detail.transcript?.segment(e.segmentID), let w = seg.words.first(where: { $0.id == e.firstWord }) else { return "?" }
        return TranscriptRows.clock(w.interval.start)
    }
}

/// A titled editor that collapses to one line (with a word count when it holds text). A plain button rather than a
/// DisclosureGroup: no animation fighting the TextEditor's height, and the whole title row is the click target.
struct CollapsibleEditor<Content: View>: View {
    let title: String
    let systemImage: String
    let hint: String?
    let help: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").appFont(.caption, weight: .bold).foregroundStyle(Color.brandSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label(title, systemImage: systemImage).appFont(.callout, weight: .medium)
                    if !isExpanded, let hint { Text(hint).appFont(.caption).foregroundStyle(Color.brandSecondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            // The editor draws its own field border; no extra box around it (T45).
            if isExpanded { content().padding(.leading, AppStyle.double) }
        }
    }
}
