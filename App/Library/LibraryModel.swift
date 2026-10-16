import Foundation
import Observation
import Domain
import Storage
import ProcessingCore
import Presentation

/// Library, search and the selected meeting's detail. Reloads (throttled) when processing changes state; all user
/// actions go through the store and scheduler, never around them.
@MainActor @Observable
final class LibraryModel {
    private(set) var items: [MeetingListItem] = []
    var selection: MeetingID? { didSet { if oldValue != selection { reloadDetail() } } }
    private(set) var detail: MeetingDetail?
    var query = "" { didSet { runSearch() } }
    private(set) var hits: [SearchHit] = []
    private(set) var error: String?
    /// Transcript row to scroll to and highlight (set by evidence links and search hits).
    var focusRowID: String?
    let store: MeetingStore?
    weak var processing: ProcessingModel?

    init(store: MeetingStore?) {
        self.store = store
        reload()
    }

    private var generation = 0

    /// Reloads the list and the open meeting off the main thread (a two-hour transcript must not stall the UI).
    func reload() {
        guard let store else { return }
        generation += 1
        let gen = generation, id = selection
        Task.detached(priority: .userInitiated) {
            let items = Result { try MeetingListItem.load(store) }
            let detail = Result { try id.flatMap { try MeetingDetail.load(store, $0) } }
            await MainActor.run {
                guard gen == self.generation else { return }
                switch items { case .success(let v): self.items = v; case .failure(let e): self.error = "Could not read the library: \(e.localizedDescription)" }
                switch detail { case .success(let v): if self.selection == id { self.detail = v }; case .failure(let e): self.error = "Could not open the meeting: \(e.localizedDescription)" }
                if !self.query.isEmpty { self.runSearch() }
            }
        }
    }

    func reloadDetail() {
        guard let store, let id = selection else { detail = nil; return }
        if detail?.meeting.id != id { detail = nil }
        Task.detached(priority: .userInitiated) {
            let d = Result { try MeetingDetail.load(store, id) }
            await MainActor.run {
                guard self.selection == id else { return }
                switch d { case .success(let v): self.detail = v; case .failure(let e): self.error = "Could not open the meeting: \(e.localizedDescription)" }
            }
        }
    }

    private func runSearch() {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; return }
        hits = (try? store.search(query)) ?? []
    }

    func open(_ hit: SearchHit) {
        selection = hit.meetingID
        if hit.kind == .transcript, let d = detail {
            focusRowID = d.rows.first { $0.segmentID?.rawValue == hit.ref }?.id
        }
    }

    func dismissError() { error = nil }

    // MARK: Actions

    func rename(_ id: MeetingID, to title: String) {
        guard let store, var m = try? store.meeting(id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.title else { return }
        m.title = t
        let updated = m
        perform { try store.upsertMeeting(updated) }
    }

    /// Stores a user edit and re-runs speaker reconciliation (cheap); notes become stale, never silently rewritten.
    func apply(_ edit: UserEdit) {
        guard let store else { return }
        let scheduler = processing?.scheduler
        perform {
            try store.appendEdit(edit)
            if case .correctText = edit.operation { return }   // text corrections are applied at display time
            try scheduler?.enqueueReconcile(edit.meetingID)
        }
    }

    func regenerateNotes(_ id: MeetingID) {
        let scheduler = processing?.scheduler
        perform { _ = try scheduler?.enqueueNotes(id) }
    }

    /// `immediately`: write synchronously (used when flushing on meeting switch or quit, so nothing typed is lost).
    func saveUserNotes(_ id: MeetingID, markdown: String, immediately: Bool = false) {
        guard let store else { return }
        if immediately {
            if (try? store.latestManualNotes(id))?.markdown != markdown {
                try? store.saveManualNotes(ManualNotesRevision(meetingID: id, basedOnSummaryRevisionID: try? store.currentSummary(id)?.id,
                                                               markdown: markdown, createdAt: Date()))
            }
            return
        }
        perform {
            guard try store.latestManualNotes(id)?.markdown != markdown else { return }
            try store.saveManualNotes(ManualNotesRevision(meetingID: id, basedOnSummaryRevisionID: try store.currentSummary(id)?.id,
                                                          markdown: markdown, createdAt: Date()))
        }
    }

    /// Each change is a new scratchpad revision (summaries cite scratchpad text by revision and offset).
    func saveScratchpad(_ id: MeetingID, text: String, include: Bool, immediately: Bool = false) {
        guard let store else { return }
        if immediately {
            let current = try? store.latestScratchpad(id)
            if current?.text != text || current?.includeInSummary != include {
                try? store.saveScratchpad(ScratchpadRevision(meetingID: id, text: text, includeInSummary: include, createdAt: Date()))
            }
            return
        }
        perform {
            let current = try store.latestScratchpad(id)
            guard current?.text != text || current?.includeInSummary != include else { return }
            try store.saveScratchpad(ScratchpadRevision(meetingID: id, text: text, includeInSummary: include, createdAt: Date()))
        }
    }

    func delete(_ action: DestructiveAction, _ id: MeetingID) {
        let scheduler = processing?.scheduler
        if action == .deleteMeeting, selection == id { selection = nil }
        perform {
            switch action {
            case .deleteAudioOnly: try scheduler?.deleteAudio(id)
            case .deleteMeeting: try scheduler?.delete(id)
            }
        }
    }

    func retry(_ id: MeetingID) { processing?.retry(id); reload() }
    func process(_ id: MeetingID) { processing?.enqueue(id); reload() }

    /// Runs store/scheduler work off the main thread, then refreshes.
    private func perform(_ body: @escaping @Sendable () throws -> Void) {
        Task.detached(priority: .userInitiated) {
            let r = Result { try body() }
            await MainActor.run {
                if case .failure(let e) = r { self.error = e.localizedDescription }
                self.reload()
            }
        }
    }
}
