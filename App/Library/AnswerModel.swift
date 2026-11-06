import Foundation
import Observation
import Contextual
import Domain
import Storage
import Presentation

/// The XPC worker as contextual retrieval's model provider (T115): plans and query vectors are foreground requests.
struct WorkerContextModels: ContextualModels {
    let worker: WorkerClient
    func plan(requestID: String, question: String, history: [AnswerTurn]) async throws -> PlanResponse {
        let r = try await worker.send(.plan(PlanRequest(requestID: requestID, question: question, history: history)), timeout: .seconds(10))
        guard case .plan(let p) = r else { throw WorkerClient.ClientError.remote("plan: \(r)") }
        return p
    }
    func embedQueries(requestID: String, texts: [String]) async throws -> EmbedResponse {
        let r = try await worker.send(.embed(EmbedRequest(requestID: requestID, texts: texts, query: true, foreground: true)), timeout: .seconds(10))
        guard case .embeddings(let e) = r else { throw WorkerClient.ClientError.remote("embed: \(r)") }
        return e
    }
    func cancel(requestID: String) { Task { @MainActor in worker.cancel(JobID(requestID)) } }
}

/// “Ask anything” answers (T54; contextual since T115, spec 0010): one foreground attempt plans the question, searches
/// transcripts by meaning and words within the scope and meeting dates, and asks the local model for an answer citing
/// the passages it read. Every attempt ends in an explicit state within `ContextualLimits.deadline` (15 s) of the
/// Return key — a checked answer, a labeled partial one, a clarification, no evidence, unavailable, stale or a timeout
/// with Retry — and streamed text is never left on screen as if it were the checked answer.
@MainActor @Observable
final class AnswerModel {
    enum Phase: Equatable {
        case idle
        /// In progress; the loading view shows the stage.
        case working(AskStage)
        /// Not answering yet (transcription is using the models); still inside the attempt's deadline.
        case waiting(String)
        case unavailable(String)
        case streaming
        case done
        case failed(String)
        /// The 15-second limit passed before a checked answer.
        case timedOut
        case clarification(String)
        /// Searched; nothing in scope supports an answer.
        case noEvidence(String)
        /// A source changed or was deleted while answering; the result was withheld.
        case stale
    }

    private(set) var phase: Phase = .idle
    private(set) var question = ""
    /// The answer as streamed so far, then the checked answer.
    private(set) var text = ""
    private(set) var response: AnswerResponse?
    /// Passages sent with the question, in prompt order (citation n is `passages[n - 1]`).
    private(set) var passages: [Passage] = []
    private(set) var acrossMeetings = false
    /// What was searched and what limits the answer (date range, coverage, keyword-only, who “I” is).
    private(set) var notes: [String] = []
    /// When the current attempt started (the deadline counts from here).
    private(set) var submittedAt: Date?
    private var scopeAsked: MeetingID?
    private var folderAsked: FolderID?
    /// Earlier questions and answers of this ask session (T55), newest last, at most `AskFollowUp.maxTurns`.
    private(set) var history: [AnswerTurn] = []
    private var lastConstraints: ResolvedConstraints?

    let store: MeetingStore?
    let worker: WorkerClient?
    /// Why the model can't run now because a recording is in progress (terminal at once), or nil.
    var recordingReason: () -> String? = { nil }
    /// Why the model must wait (transcription using the speech models), or nil. Waited out inside the deadline.
    var busyReason: () -> String? = { nil }
    var modelReady: () -> Bool = { false }
    /// The search model is installed. Ask always searches by meaning: without it there is no answer (no keyword-only Ask).
    var searchReady: () -> Bool = { false }
    /// The encoder producer whose vectors are searched (from the indexer); nil → the one that embeds the question.
    var producer: () -> EncoderProducer? = { nil }
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var requestID: String?

    init(store: MeetingStore?, worker: WorkerClient?) {
        self.store = store
        self.worker = worker
    }

    var citedPassages: [Passage] { (response?.citations ?? []).compactMap { passages.indices.contains($0 - 1) ? passages[$0 - 1] : nil } }
    var isWorking: Bool {
        switch phase { case .working, .streaming, .waiting: true; default: false }
    }
    /// A terminal state that offers Retry.
    var canRetry: Bool {
        switch phase { case .timedOut, .failed, .unavailable, .stale: true; default: false }
    }

    /// Asks `question` over one meeting (`meeting`), a folder (`folder`) or all meetings (both nil). Asking the same
    /// question again over the same scope keeps the answer already shown or in progress.
    func ask(_ q: String, in meeting: MeetingID?, folder: FolderID? = nil, force: Bool = false) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let store else { return }
        if !force, q == question, meeting == scopeAsked, folder == folderAsked, phase != .idle, !canRetry { return }
        cancel()
        if meeting != scopeAsked || folder != folderAsked { history = []; lastConstraints = nil }
        if history.last?.question == q { history.removeLast() }
        let context = history
        // Only a follow-up (“and who owns it?”) inherits the previous turn's subject and dates; any other question in the
        // session starts fresh for retrieval (earlier turns still give the answer context).
        let followUp = !context.isEmpty && AskFollowUp.isFollowUp(q)
        let previous = followUp ? lastConstraints : nil
        question = q; scopeAsked = meeting; folderAsked = folder; acrossMeetings = meeting == nil
        text = ""; response = nil; passages = []; notes = []
        phase = .working(.preparing)   // visible within a frame of Return
        let id = UUID().uuidString
        requestID = id
        let submitted = Date()
        submittedAt = submitted
        let deadline = submitted.addingTimeInterval(ContextualLimits.deadline - ContextualLimits.deliveryMargin)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
            guard let self, !Task.isCancelled, self.requestID == id, self.isWorking else { return }
            self.timeOut(id)
        }
        let scope: ContextualRequest.Scope = meeting.map { .meeting($0) } ?? folder.map { .folder($0) } ?? .all
        let request = ContextualRequest(question: q, scope: scope, requestTime: submitted, timeZoneIdentifier: TimeZone.current.identifier, history: followUp ? context : [])
        task = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { if Task.isCancelled { return false }; return self.requestID == id }
            guard self.modelReady(), let worker = self.worker else {
                self.end(id, .unavailable("Ask needs the local models. Install them in Settings → Models.")); return
            }
            guard self.searchReady() else {
                self.end(id, .unavailable("Ask needs the search model. Install it in Settings → Models.")); return
            }
            if let r = self.recordingReason() { self.end(id, .unavailable(r)); return }
            while let reason = self.busyReason() {
                self.phase = .waiting(reason)
                // Leave enough of the 15 s for planning and answering; otherwise say so now instead of spinning.
                if deadline.timeIntervalSinceNow < 9 { self.end(id, .unavailable(reason.replacingOccurrences(of: "…", with: ".") + " Ask again in a moment.")); return }
                try? await Task.sleep(for: .milliseconds(300))
                guard current() else { return }
            }
            self.phase = .working(.searching)
            let retriever = ContextualRetriever(store: store, models: WorkerContextModels(worker: worker), producer: self.producer(), learnsProducer: true,
                                                accountName: NSFullUserName())
            let evidence: ContextualEvidence
            do {
                evidence = try await retriever.retrieve(request, previous: previous, requestID: id,
                                                        planDeadline: min(Date().addingTimeInterval(ContextualLimits.planningBudget), deadline.addingTimeInterval(-8)))
            } catch {
                guard current() else { return }
                self.end(id, .failed("The search could not run: \(error.localizedDescription)")); return
            }
            guard current() else { return }
            // No keyword-only answers: the search model must have read the question.
            guard evidence.semantic else { self.end(id, .failed("The search model couldn't read the question. Try again.")); return }
            // Nothing indexed yet (just after the search model installed): an answer now would rest on exact words alone.
            if evidence.coverage.meetingsInScope > 0, evidence.coverage.meetingsIndexed == 0 {
                self.end(id, .unavailable("Your meetings are still being prepared for search (it runs when nothing else is). Ask again in a moment.")); return
            }
            let tz = TimeZone.current
            self.notes = ContextualAsk.notes(evidence, timeZone: tz)
            self.lastConstraints = evidence.constraints
            switch ContextualAsk.compose(evidence, request: request, requestID: id) {
            case .clarify(let t): self.end(id, .clarification(t)); return
            case .noEvidence(let t): self.end(id, .noEvidence(t)); return
            case .answer(var answerRequest, let ordered):
                answerRequest.history = context
                self.passages = ordered
                self.phase = .working(.reading)
                guard self.fresh(evidence, ordered) else { self.end(id, .stale); return }
                self.phase = .working(.answering)
                worker.registerAnswer(id) { partial in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id, self.response == nil, !partial.isEmpty, self.isWorking else { return }
                        self.text = partial
                        self.phase = .streaming
                    }
                }
                defer { worker.unregisterAnswer(id) }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 1 else { self.timeOut(id); return }
                do {
                    let r = try await worker.send(.answer(answerRequest), timeout: .seconds(remaining))
                    guard current() else { return }
                    switch r {
                    case .answer(let a):
                        guard self.fresh(evidence, a.citations.compactMap { ordered.indices.contains($0 - 1) ? ordered[$0 - 1] : nil }) else { self.end(id, .stale); return }
                        if !a.refused, let v = ContextualAsk.attributionViolation(a.text, evidence.constraints) { self.end(id, .clarification(v)); return }
                        self.answeredGenerations = evidence.generations
                        self.finish(a, partial: !evidence.coverage.complete && evidence.semantic)
                    case .cancelled: break
                    case .failed(_, let code): self.end(id, .failed("The local model could not answer (\(code.prefix(80)))."))
                    default: self.end(id, .failed("Unexpected reply from the worker."))
                    }
                } catch {
                    guard current() else { return }
                    if Date() >= deadline.addingTimeInterval(-0.5) { self.timeOut(id) } else { self.end(id, .failed("The local model could not answer: \(error.localizedDescription)")) }
                }
            }
        }
    }

    /// The sources haven't changed since they were read (edits, retranscription, deletion bump the generation).
    private func fresh(_ e: ContextualEvidence, _ used: [Passage]) -> Bool {
        let ids = Set(used.map(\.meetingID))
        guard !ids.isEmpty, let store else { return true }
        let now = (try? store.contextGenerations(ids)) ?? [:]
        return ids.allSatisfy { now[$0] != nil && now[$0] == e.generations[$0] }
    }

    private func timeOut(_ id: String) {
        guard requestID == id else { return }
        if let worker { for suffix in ["", "-plan", "-q", "-x"] { worker.cancel(JobID(id + suffix)) } }
        task?.cancel()
        text = ""; response = nil
        end(id, .timedOut)
    }

    private func end(_ id: String, _ p: Phase) {
        guard requestID == id else { return }
        watchdog?.cancel(); watchdog = nil
        phase = p
    }

    private func finish(_ a: AnswerResponse, partial: Bool) {
        watchdog?.cancel(); watchdog = nil
        response = a
        text = a.text
        phase = .done
        if partial, !a.refused, !notes.contains(where: { $0.hasPrefix("Still getting") }) {
            notes.append("Contextual search hasn't finished indexing every meeting yet; this answer may be incomplete.")
        }
        if !a.refused { history = Array((history + [AnswerTurn(question: question, answer: a.text)]).suffix(AskFollowUp.maxTurns)) }
    }

    /// Retry after a timeout, failure, “unavailable” or stale result: a new attempt with its own 15 s.
    func retry() {
        ask(question, in: scopeAsked, folder: folderAsked, force: true)
    }

    /// Generations of the passages behind the shown answer (for `sourcesChanged`).
    private var answeredGenerations: [MeetingID: Int64] = [:]

    /// Sources changed (edit, deletion): a finished answer that cites them is marked stale.
    func sourcesChanged() {
        guard phase == .done, let store, !citedPassages.isEmpty else { return }
        let ids = Set(citedPassages.map(\.meetingID))
        let now = (try? store.contextGenerations(ids)) ?? [:]
        if ids.contains(where: { now[$0] == nil || (answeredGenerations[$0] != nil && now[$0] != answeredGenerations[$0]) }) {
            phase = .stale; response = nil; text = ""
        }
    }

    /// The panel closed: the next question starts a new conversation.
    func endSession() {
        cancel()
        history = []
        lastConstraints = nil
    }

    /// Esc, a new question, or closing the panel. Acknowledged at once: the loading view stops and the worker cancels.
    func cancel() {
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        if let id = requestID, isWorking {
            worker?.cancel(JobID(id))
            for suffix in ["-plan", "-q", "-x"] { worker?.cancel(JobID(id + suffix)) }
        }
        requestID = nil
        if isWorking { phase = .idle }
    }

    func reset() {
        cancel()
        history = []
        lastConstraints = nil
        phase = .idle; question = ""; text = ""; response = nil; passages = []; notes = []
    }

    #if DEBUG
    /// ui-render: show a state without the model.
    func showForRender(question: String, passages: [Passage], response: AnswerResponse?, phase: Phase, acrossMeetings: Bool, history: [AnswerTurn] = [],
                       notes: [String] = []) {
        self.history = history
        self.question = question; self.passages = passages; self.response = response; self.text = response?.text ?? ""
        self.phase = phase; self.acrossMeetings = acrossMeetings; self.notes = notes; self.submittedAt = Date()
    }
    #endif
}
