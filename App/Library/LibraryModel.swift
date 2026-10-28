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
    /// Single-level folders (T39/T40), in the store's order.
    private(set) var folders: [Folder] = []
    /// The sidebar's folder filter (T40): nil shows all meetings. Kept across launches; a deleted folder falls back to all.
    var folderFilter: FolderID? = UserDefaults.standard.string(forKey: LibraryModel.folderFilterKey).map(FolderID.init) {
        didSet { UserDefaults.standard.set(folderFilter?.rawValue, forKey: Self.folderFilterKey) }
    }
    static let folderFilterKey = "sidebarFolderFilter"
    /// The meetings the sidebar lists under the current filter.
    var visibleItems: [MeetingListItem] { LibraryFolders.visible(items, filter: folderFilter) }
    var folderRows: [LibraryFolders.Row] { LibraryFolders.rows(folders, items: items) }
    func folderName(_ id: FolderID?) -> String? { LibraryFolders.name(id, in: folders) }
    var selection: MeetingID? { didSet { if oldValue != selection { reloadDetail(); if askPanelOpen, askScope == .thisMeeting { runSearch() } } } }
    private(set) var detail: MeetingDetail?
    /// The “Ask anything” field's text (T52). Searched on submit, then live while the results panel is open.
    /// Only a real change re-searches and drops the ↑/↓ highlight: the field re-sets the same text when Return commits it,
    /// and that must not clear the hit Return is about to open.
    var query = "" { didSet { guard query != oldValue else { return }; if askPanelOpen { runSearch() }; askSelection = nil } }
    private(set) var hits: [SearchHit] = []
    /// “This meeting” (the meeting on screen) or “All meetings”; ⌘K switches to All meetings.
    var askScope: AskScope = .thisMeeting { didSet { if askPanelOpen { runSearch(); reaskIfAnswered() } } }
    private(set) var askPanelOpen = false
    /// Hit highlighted with ↑/↓ (index into the panel's flattened order); Return opens it.
    var askSelection: Int?
    /// A hit or citation opened in a meeting that is still loading: applied once its detail arrives.
    private var pendingJump: Jump?
    private enum Jump { case hit(SearchHit), evidence(MeetingID, TranscriptEvidence?, notes: Bool) }
    /// T54: answers from the local model, shown above the matches. Nil in contexts without a worker (ui-render).
    var answers: AnswerModel?
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
    enum DetailTab: String, CaseIterable { case notes = "Notes", transcript = "Transcript", recording = "Audio details" }
    /// Bumped by ⌘K; the ask field takes focus.
    var askFocusRequest = 0
    /// Set with each request until the field takes it: the Ask pane may be hidden, so the field appears after the bump.
    var askFocusPending = false
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
            let folders = Result { try store.folders() }
            let detail = Result { try id.flatMap { try MeetingDetail.load(store, $0) } }
            await MainActor.run {
                guard gen == self.generation else { return }
                switch items { case .success(let v): self.items = v; case .failure(let e): self.error = "Could not read the library: \(e.localizedDescription)" }
                if case .success(let f) = folders {
                    self.folders = f
                    let valid = LibraryFolders.validFilter(self.folderFilter, folders: f)
                    if valid != self.folderFilter { self.folderFilter = valid }
                }
                switch detail { case .success(let v): if self.selection == id { self.show(v) }; case .failure(let e): self.error = "Could not open the meeting: \(e.localizedDescription)" }
                if self.askPanelOpen { self.runSearch() }
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
        switch pendingJump {
        case .hit(let hit) where hit.meetingID == id: pendingJump = nil; jump(to: hit, in: d)
        case .evidence(let m, let e, let notes) where m == id: pendingJump = nil; jump(to: e, notes: notes, in: d)
        default: break
        }
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

    // MARK: Ask anything (T52)

    /// ⌘K: focus the field with All meetings as the scope.
    func askAllMeetings() {
        askScope = .allMeetings
        askFocusPending = true
        askFocusRequest += 1
    }

    /// Return in the field: open the highlighted hit, or (re)run the search and show the panel.
    func submitAsk() {
        if askPanelOpen, let i = askSelection {
            let shown = AskResults.flattened(AskResults.grouped(hits))
            if shown.indices.contains(i) { open(shown[i]) }
            return
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        askPanelOpen = true
        runSearch()
        answers?.ask(query, in: AskResults.effectiveScope(askScope, meeting: selection))
    }

    /// The scope switched with an answer on screen: answer again over the new scope.
    private func reaskIfAnswered() {
        guard let answers, answers.phase != .idle, !answers.question.isEmpty else { return }
        answers.ask(answers.question, in: AskResults.effectiveScope(askScope, meeting: selection))
    }

    func moveAskSelection(by delta: Int) {
        guard askPanelOpen else { return }
        askSelection = AskResults.move(askSelection, by: delta, count: hits.count)
    }

    /// Esc, a click outside, or opening a hit. The text stays, so Return shows the same results again.
    func closeAskPanel() {
        askPanelOpen = false
        askSelection = nil
        answers?.endSession()
    }

    // MARK: Meeting actions (T79): asked for from the shared ⋯ / right-click menu, presented once by MainView.

    struct ActionRequest: Identifiable {
        enum Kind { case rename, destructive(DestructiveAction) }
        let id = UUID()
        let kind: Kind
        let meetingID: MeetingID
        let title: String
    }
    var actionRequest: ActionRequest?
    var renameRequest: ActionRequest? { if case .rename = actionRequest?.kind { actionRequest } else { nil } }
    var deleteRequest: (request: ActionRequest, action: DestructiveAction)? {
        if let r = actionRequest, case .destructive(let a) = r.kind { (r, a) } else { nil }
    }

    func requestRename(_ id: MeetingID, title: String) { actionRequest = .init(kind: .rename, meetingID: id, title: title) }
    func requestDelete(_ action: DestructiveAction, _ id: MeetingID, title: String) {
        actionRequest = .init(kind: .destructive(action), meetingID: id, title: title)
    }

    /// Exports any meeting, open or not: the open one's loaded detail, or a fresh load from the store.
    func export(_ format: MeetingExport.Format, _ id: MeetingID) {
        guard let d = loadedDetail(id) else { return }
        MeetingExport.run(format, d, folderName: folderName(d.meeting.folderID))
    }

    /// Copies any meeting's original audio segments (no transcript needed).
    func exportAudio(_ id: MeetingID) {
        guard let store, let d = loadedDetail(id) else { return }
        MeetingExport.exportAudio(d, store: store)
    }

    private func loadedDetail(_ id: MeetingID) -> MeetingDetail? {
        guard let store else { return nil }
        return detail?.meeting.id == id ? detail : (try? MeetingDetail.load(store, id)) ?? nil
    }

    /// × and Esc (T78): clear the results and the question, then put the cursor back in the ask field for the next one.
    func clearAsk() {
        closeAskPanel()
        query = ""
        hits = []
        askFocusPending = true
        askFocusRequest += 1
    }

    private func runSearch() {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; return }
        // Questions search by their content words (“when will they ship?” → “ship”), like the retriever (T54).
        let terms = Retriever.terms(query).joined(separator: " "), scope = AskResults.effectiveScope(askScope, meeting: selection)
        hits = (try? store.search(terms, in: scope)) ?? []
        // A question rarely has every word on one line: then list lines with any of them, best first.
        if hits.isEmpty { hits = (try? store.search(terms, in: scope, anyTerm: true)) ?? [] }
        if let i = askSelection, i >= hits.count { askSelection = nil }
    }

    /// Opens the hit's meeting at the match: the transcript row for transcript hits, the Notes tab for notes. The results
    /// stay in the Ask pane, so the next match is a click away.
    func open(_ hit: SearchHit) {
        if selection == hit.meetingID, let d = detail, d.meeting.id == hit.meetingID {
            jump(to: hit, in: d)
        } else {
            pendingJump = .hit(hit)
            selection = hit.meetingID
        }
    }

    /// A citation chip (T54): the cited line in the transcript, like a notes evidence link; a note without transcript
    /// evidence opens Notes. The panel stays open so the other citations remain a click away.
    func open(citation p: Passage) {
        let e = AskPassages.jumpEvidence(p), notes = p.source == .notes && e == nil
        if selection == p.meetingID, let d = detail, d.meeting.id == p.meetingID {
            jump(to: e, notes: notes, in: d)
        } else {
            pendingJump = .evidence(p.meetingID, e, notes: notes)
            selection = p.meetingID
        }
    }

    private func jump(to e: TranscriptEvidence?, notes: Bool, in d: MeetingDetail) {
        guard !notes, let e, let t = d.transcript, let row = TranscriptRows.row(for: e, in: d.rows, revision: t) else { detailTab = .notes; return }
        detailTab = .transcript
        focusRowID = row.id
    }

    private func jump(to hit: SearchHit, in d: MeetingDetail) {
        switch hit.kind {
        case .transcript:
            detailTab = .transcript
            focusRowID = d.rows.first { $0.segmentID?.rawValue == hit.ref }?.id
        case .notes, .userNotes: detailTab = .notes
        case .speaker: detailTab = .transcript
        case .title, .person: break
        }
    }

    func dismissError() { error = nil }

    // MARK: Folders (T40): New Folder…, Rename… and Delete Folder… are asked for here and presented once by MainView.

    enum FolderRequest: Identifiable {
        /// `moving`: the meeting whose Move to Folder ▸ New Folder… asked for it, filed in the new folder once created.
        case create(moving: MeetingID?)
        case rename(Folder)
        case delete(Folder)
        var id: String {
            switch self {
            case .create(let m): "create-\(m?.rawValue ?? "")"
            case .rename(let f): "rename-\(f.id)"
            case .delete(let f): "delete-\(f.id)"
            }
        }
    }
    var folderRequest: FolderRequest?
    var folderNameRequest: FolderRequest? { if case .delete = folderRequest { nil } else { folderRequest } }
    var folderDeleteRequest: Folder? { if case .delete(let f) = folderRequest { f } else { nil } }

    var filteredFolder: Folder? { folderFilter.flatMap { id in folders.first { $0.id == id } } }
    func meetingCount(in folder: FolderID) -> Int { items.filter { $0.folderID == folder }.count }

    /// Creates a folder. From the sidebar it opens the new folder; from a meeting's menu it files that meeting there and
    /// keeps the current filter.
    func createFolder(named name: String, moving meeting: MeetingID? = nil) {
        guard let store else { return }
        Task.detached(priority: .userInitiated) {
            let r = Result { () throws -> Folder in
                let f = try store.createFolder(name: name)
                if let meeting { try store.moveMeeting(meeting, to: f.id) }
                return f
            }
            await MainActor.run {
                switch r {
                case .success(let f): if meeting == nil { self.folders.append(f); self.folderFilter = f.id }
                case .failure(let e): self.error = e.localizedDescription
                }
                self.reload()
            }
        }
    }

    func renameFolder(_ id: FolderID, to name: String) {
        guard let store else { return }
        perform { try store.renameFolder(id, to: name) }
    }

    /// Deletes only the folder: its meetings become unfiled (MeetingStore.deleteFolder never touches their content).
    func deleteFolder(_ id: FolderID) {
        guard let store else { return }
        if folderFilter == id { folderFilter = nil }
        perform { try store.deleteFolder(id) }
    }

    /// Files a meeting in a folder, or unfiles it with nil.
    func move(_ meeting: MeetingID, to folder: FolderID?) {
        guard let store else { return }
        perform { try store.moveMeeting(meeting, to: folder) }
    }

    // MARK: Actions

    func rename(_ id: MeetingID, to title: String) {
        guard let store, var m = try? store.meeting(id), let t = MeetingTitle.renamed(from: m.title, to: title) else { return }
        m.title = t
        let updated = m
        perform { try store.upsertMeeting(updated) }
    }

    /// Header people chip (T50). Stored through the store's setter so a recorder holding an older copy can't drop them.
    func setPeople(_ id: MeetingID, _ people: [Person]) {
        guard let store else { return }
        perform { try store.setPeople(people, for: id) }
    }

    /// Header calendar chip (T57): links (or re-links / updates) the meeting to an event occurrence as a snapshot and
    /// merges its named attendees into the people (T58).
    func link(_ id: MeetingID, to event: CalendarEvent) {
        guard let store else { return }
        let keepEmails = CalendarSettings.keepEmails()
        perform { try CalendarLinking.link(event, to: id, in: store, keepEmails: keepEmails) }
    }

    /// Removes the link only; people added from the event stay (user decision 2026-10-27).
    func unlink(_ id: MeetingID) {
        guard let store else { return }
        perform { try store.setLinkedEvent(nil, for: id) }
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
