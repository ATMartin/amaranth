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
    /// The meeting screen's tab; here (not view state) so menu commands (⌘1–⌘3) can switch it. Any change not made by
    /// the T32 rules counts as the user's choice for the open meeting and is kept for this session.
    var detailTab: DetailTab = .notes {
        didSet { if !applyingTabRule, let id = selection { chosenTabs[id] = detailTab; notesSwitch.userChoseTab(id) } }
    }
    private var applyingTabRule = false
    private var chosenTabs: [MeetingID: DetailTab] = [:]
    private var notesSwitch = NotesArrivalSwitch()
    /// The meeting the open detail's tab was chosen for, so a refresh of the same meeting keeps the tab.
    private var tabAppliedFor: MeetingID?
    /// Set by the app: whether the notes model is installed (no model → never auto-switch to Notes).
    var notesModelReady: () -> Bool = { false }
    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript", recording = "Recording" }
    /// Bumped by ⌘K; MainView focuses the search field.
    var searchFocusRequest = 0
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
                switch detail { case .success(let v): if self.selection == id { self.show(v) }; case .failure(let e): self.error = "Could not open the meeting: \(e.localizedDescription)" }
                if !self.query.isEmpty { self.runSearch() }
            }
        }
    }

    func reloadDetail() {
        guard let store, let id = selection else { detail = nil; tabAppliedFor = nil; return }
        if detail?.meeting.id != id { detail = nil; tabAppliedFor = nil }
        Task.detached(priority: .userInitiated) {
            let d = Result { try MeetingDetail.load(store, id) }
            await MainActor.run {
                guard self.selection == id else { return }
                switch d { case .success(let v): self.show(v); case .failure(let e): self.error = "Could not open the meeting: \(e.localizedDescription)" }
            }
        }
    }

    /// Publishes a loaded detail and applies the tab rules (T32): a newly opened meeting gets the tab the user chose for
    /// it this session, else its default; a meeting waiting for its first notes after Stop switches to Notes once.
    private func show(_ d: MeetingDetail?) {
        detail = d
        guard let d else { tabAppliedFor = nil; return }
        let id = d.meeting.id
        if tabAppliedFor != id {
            tabAppliedFor = id
            setTabByRule(chosenTabs[id] ?? (d.defaultTab(isRecording: false) == .notes ? .notes : .transcript))
        }
        if notesSwitch.shouldSwitchToNotes(viewing: id, hasSummary: d.summary != nil) { setTabByRule(.notes) }
    }

    private func setTabByRule(_ tab: DetailTab) {
        applyingTabRule = true
        detailTab = tab
        applyingTabRule = false
    }

    /// Record pressed: open the new meeting so the detail pane is its live transcript.
    func recordingStarted(_ id: MeetingID) {
        selection = id
        reload()
    }

    /// Stop: show the meeting's transcript, then Notes once when its first notes arrive (unless the user picks a tab).
    func recordingStopped(_ id: MeetingID) {
        chosenTabs[id] = nil
        notesSwitch.stopped(id, notesModelReady: notesModelReady())
        if selection == id { tabAppliedFor = id; setTabByRule(.transcript) } else { tabAppliedFor = nil; selection = id }
        reload()
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
        guard let store, var m = try? store.meeting(id), let t = MeetingTitle.renamed(from: m.title, to: title) else { return }
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
