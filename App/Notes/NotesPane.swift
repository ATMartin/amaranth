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
            VStack(alignment: .leading, spacing: AppStyle.double) {
                stateBanner
                if let s = detail.summary { generated(s) }
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
                                  hint: CollapsedEditorHint.text(for: scratchpad).map { includeScratchpad ? $0 + " · used for notes" : $0 },
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
                            .appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .appFont(.body)
            .padding(AppStyle.double)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
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
            banner("No notes yet.", "doc.text", .secondary) { Button("Generate Notes") { library.regenerateNotes(detail.meeting.id) } }
        case .waiting(let why):
            banner(why, "hourglass", .secondary) { EmptyView() }
        case .generating(let p):
            banner("Generating notes on this Mac… \(Int(p * 100))%", "gearshape.2", .secondary) { ProgressView(value: p).frame(width: 120) }
        case .failed(let code):
            banner("Notes could not be generated (\(code)). The transcript is unaffected.", "xmark.octagon", .statusFailed) {
                Button("Try Again") { library.regenerateNotes(detail.meeting.id) }
            }
        case .unavailable(let why):
            banner(why, "info.circle", .secondary) { EmptyView() }
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

    func banner<A: View>(_ text: String, _ icon: String, _ color: Color, @ViewBuilder action: () -> A) -> some View {
        HStack {
            Label(text, systemImage: icon).foregroundStyle(color)
            Spacer()
            action()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder func generated(_ s: SummaryRevision) -> some View {
        if s.influencedByPersonalNotes {
            Label("These notes also used your private scratchpad.", systemImage: "lock.doc").appFont(.caption).foregroundStyle(.secondary)
        }
        section("Overview", s.content.overview)
        section("Decisions", s.content.decisions)
        section("Action items", s.content.actionItems)
        section("Open questions", s.content.openQuestions)
        if !s.content.limitations.isEmpty {
            DisclosureGroup("Limitations (\(s.content.limitations.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.content.limitations) { Text("• " + $0.text).appFont(.callout).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [SummaryItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: AppStyle.grid) {
                Text(title).appFont(.sectionTitle)
                ForEach(items) { NoteItemRow(item: $0, detail: detail, jump: jump) }
            }
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
    @Environment(\.showDetails) private var showDetails

    var transcriptEvidence: [TranscriptEvidence] {
        item.evidence.compactMap { if case .transcript(let e) = $0 { e } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                if let t = item.title { Text(t).appFont(.body, weight: .semibold) }
                Text(item.text).textSelection(.enabled)
                if item.uncertain {
                    Image(systemName: "questionmark.circle").foregroundStyle(Color.statusAttention).help("Not fully confirmed by the transcript — check the cited passage")
                }
            }
            if item.kind == .actionItem || item.owner != nil || item.due != nil {
                Text("Owner: \(item.owner ?? "not stated")  ·  Due: \(item.due?.originalText ?? "not stated")")
                    .appFont(.caption).foregroundStyle(.secondary)
            }
            // Evidence is attribution, shown only with Details on; the uncertain marker above is a warning and always shows.
            if showDetails {
                HStack(spacing: 6) {
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, ref in
                        switch ref {
                        case .transcript(let e):
                            Button(time(e)) { jump(e) }.buttonStyle(.link).appFont(.caption, monospacedDigit: true).help("Show in transcript")
                        case .personalNote:
                            Label("your private note", systemImage: "lock").appFont(.caption).foregroundStyle(.secondary)
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
                    Image(systemName: "chevron.right").appFont(.caption, weight: .bold).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Label(title, systemImage: systemImage)
                    if !isExpanded, let hint { Text("· " + hint).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded { GroupBox { content() } }
        }
    }
}
