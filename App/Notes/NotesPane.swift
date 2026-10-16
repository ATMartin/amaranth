import SwiftUI
import AppKit
import Domain
import Presentation

/// Generated notes with their evidence, the user's own notes (never overwritten by regeneration), and the private
/// scratchpad with its explicit "include when generating notes" switch.
struct NotesPane: View {
    let detail: MeetingDetail
    let notesModelInstalled: Bool
    let showTranscript: () -> Void
    @Environment(LibraryModel.self) private var library
    @State private var userNotes = ""
    @State private var scratchpad = ""
    @State private var includeScratchpad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stateBanner
                if let s = detail.summary { generated(s) }
                GroupBox {
                    TextEditor(text: $userNotes).font(.body).frame(minHeight: 120)
                        .onChange(of: userNotes) { _, v in
                            let id = detail.meeting.id
                            debounceSave("notes") { now in library.saveUserNotes(id, markdown: v, immediately: now) }
                        }
                } label: {
                    Label("Your notes", systemImage: "square.and.pencil")
                        .help("Yours alone: regenerating notes never changes this text.")
                }
                GroupBox {
                    VStack(alignment: .leading) {
                        TextEditor(text: $scratchpad).frame(minHeight: 80)
                            .onChange(of: scratchpad) { _, v in
                                let id = detail.meeting.id
                                // Read the switch when the save runs, not when typing happened (flipping it within the
                                // debounce window must not be reverted).
                                debounceSave("scratchpad") { now in library.saveScratchpad(id, text: v, include: includeScratchpad, immediately: now) }
                            }
                        Toggle("Use these private notes when generating notes", isOn: $includeScratchpad)
                            .onChange(of: includeScratchpad) { _, v in
                                pending["scratchpad"]?.task.cancel(); pending["scratchpad"] = nil   // this save includes the latest text
                                library.saveScratchpad(detail.meeting.id, text: scratchpad, include: v)
                            }
                        Text("Private: not exported or searched unless you choose to. Notes that used them are labelled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } label: { Label("Private scratchpad", systemImage: "lock") }
            }
            .padding()
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

    @State private var pending: [String: (task: Task<Void, Never>, run: PendingSave)] = [:]
    final class PendingSave { let run: @MainActor (Bool) -> Void; init(_ r: @escaping @MainActor (Bool) -> Void) { run = r } }

    /// Saves `field` after 1 s without typing; a newer edit of the same field replaces its pending save. Each field has
    /// its own slot, so typing in one editor never cancels the other's save.
    func debounceSave(_ field: String, _ save: @escaping @MainActor (_ immediately: Bool) -> Void) {
        pending[field]?.task.cancel()
        let action = PendingSave(save)
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            action.run(false)
            if pending[field]?.run === action { pending[field] = nil }
        }
        pending[field] = (task, action)
    }

    /// Writes pending saves synchronously (meeting switch, closing, quitting) so typed text is never lost.
    func flushPendingSave() {
        for (_, p) in pending { p.task.cancel(); p.run.run(true) }
        pending = [:]
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
            banner("Notes could not be generated (\(code)). The transcript is unaffected.", "xmark.octagon", .red) {
                Button("Try Again") { library.regenerateNotes(detail.meeting.id) }
            }
        case .unavailable(let why):
            banner(why, "info.circle", .secondary) { EmptyView() }
        case .ready(let stale, let failure):
            if stale {
                banner("The transcript or speakers changed after these notes were made.", "exclamationmark.arrow.circlepath", .orange) {
                    Button("Regenerate") { library.regenerateNotes(detail.meeting.id) }
                }
            }
            if let failure {
                banner("Regenerating failed (\(failure)); these are the previous notes.", "exclamationmark.triangle", .orange) {
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
            Label("These notes also used your private scratchpad.", systemImage: "lock.doc").font(.caption).foregroundStyle(.secondary)
        }
        section("Overview", s.content.overview)
        section("Decisions", s.content.decisions)
        section("Action items", s.content.actionItems)
        section("Open questions", s.content.openQuestions)
        section("Topics", s.content.topics)
        if !s.content.limitations.isEmpty {
            DisclosureGroup("Limitations (\(s.content.limitations.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.content.limitations) { Text("• " + $0.text).font(.callout).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [SummaryItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                if let t = item.title { Text(t).bold() }
                Text(item.text).textSelection(.enabled)
                if item.uncertain {
                    Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("Not fully confirmed by the transcript — check the cited passage")
                }
            }
            if item.kind == .actionItem || item.owner != nil || item.due != nil {
                Text("Owner: \(item.owner ?? "not stated")  ·  Due: \(item.due?.originalText ?? "not stated")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, ref in
                    switch ref {
                    case .transcript(let e):
                        Button(time(e)) { jump(e) }.buttonStyle(.link).font(.caption.monospacedDigit()).help("Show in transcript")
                    case .personalNote:
                        Label("your private note", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func time(_ e: TranscriptEvidence) -> String {
        guard let seg = detail.transcript?.segment(e.segmentID), let w = seg.words.first(where: { $0.id == e.firstWord }) else { return "?" }
        return TranscriptRows.clock(w.interval.start)
    }
}
