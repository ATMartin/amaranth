import Foundation
import Observation
import Domain
import Storage
import Presentation

/// “Ask anything” answers (T54): retrieves passages for the question (T53), then asks the notes model in the worker for
/// an answer that cites them, streaming it in. The model only runs when nothing else needs the Mac's ML resources:
/// loading it would release the speech models, so answers wait while transcript work is queued or running and are
/// paused while recording (the panel still shows the search matches).
@MainActor @Observable
final class AnswerModel {
    enum Phase: Equatable {
        case idle
        /// Retrieving passages, or the model is reading them (before the first word).
        case thinking
        /// Not answering now; the reason is shown and matches stay available.
        case waiting(String)
        case unavailable(String)
        case streaming
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var question = ""
    /// The answer as streamed so far, then the checked answer.
    private(set) var text = ""
    private(set) var response: AnswerResponse?
    /// Passages sent with the question, in prompt order (citation n is `passages[n - 1]`).
    private(set) var passages: [Passage] = []
    private(set) var acrossMeetings = false
    private var scopeAsked: MeetingID?
    private var folderAsked: FolderID?
    /// Earlier questions and answers of this ask session (T55), newest last, at most `AskFollowUp.maxTurns`. A follow-up
    /// like “and when is it due?” is answered with them as context. Cleared when the scope or meeting changes or the
    /// panel closes.
    private(set) var history: [AnswerTurn] = []

    let store: MeetingStore?
    let worker: WorkerClient?
    /// Why the model can't run now (recording, transcription), or nil.
    var busyReason: () -> String? = { nil }
    var modelReady: () -> Bool = { false }
    private var task: Task<Void, Never>?
    private var requestID: String?

    init(store: MeetingStore?, worker: WorkerClient?) {
        self.store = store
        self.worker = worker
    }

    var citedPassages: [Passage] { (response?.citations ?? []).compactMap { passages.indices.contains($0 - 1) ? passages[$0 - 1] : nil } }
    var isWorking: Bool { [.thinking, .streaming].contains(phase) || { if case .waiting = phase { true } else { false } }() }

    /// Asks `question` over one meeting (`meeting`) or all meetings (nil). Asking the same question again over the same
    /// scope keeps the answer already shown or in progress.
    /// `folder` (T42): only that folder's meetings (with `meeting` nil).
    func ask(_ q: String, in meeting: MeetingID?, folder: FolderID? = nil) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let store else { return }
        if q == question, meeting == scopeAsked, folder == folderAsked, phase != .idle, !{ if case .failed = phase { true } else { false } }() { return }
        cancel()
        if meeting != scopeAsked || folder != folderAsked { history = [] }
        // Asked again (scope switch): the earlier turn of this same question isn't context for itself.
        if history.last?.question == q { history.removeLast() }
        let context = history
        question = q; scopeAsked = meeting; folderAsked = folder; acrossMeetings = meeting == nil
        text = ""; response = nil; passages = []
        phase = .thinking
        let id = UUID().uuidString
        requestID = id
        task = Task { [weak self] in
            let query = AskFollowUp.retrievalQuery(q, history: context)
            let found = await Task.detached(priority: .userInitiated) { (try? Retriever(store: store).search(query, in: meeting, folder: folder)) ?? [] }.value
            guard let self, !Task.isCancelled, self.requestID == id else { return }
            self.passages = found
            guard !found.isEmpty else {
                self.finish(AnswerResponse(text: AnswerResponse.refusalText, citations: [], confidence: .low, refused: true, checkerNote: "no passages",
                                           promptTokens: 0, generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0))
                return
            }
            guard self.modelReady(), let worker = self.worker else {
                self.phase = .unavailable("Answers need the notes model (Models in the toolbar). The search matches are below.")
                return
            }
            while let reason = self.busyReason() {
                self.phase = .waiting(reason)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.requestID == id else { return }
            }
            self.phase = .thinking
            worker.registerAnswer(id) { partial in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == id, self.response == nil, !partial.isEmpty else { return }
                    self.text = partial
                    self.phase = .streaming
                }
            }
            defer { worker.unregisterAnswer(id) }
            let request = AnswerRequest(requestID: id, question: q, passages: AskPassages.render(found, acrossMeetings: meeting == nil), history: context)
            do {
                let r = try await worker.send(.answer(request), timeout: .seconds(120))
                guard self.requestID == id else { return }
                switch r {
                case .answer(let a): self.finish(a)
                case .cancelled: break
                case .failed(_, let code): self.phase = .failed("The local model could not answer (\(code.prefix(80))).")
                default: self.phase = .failed("Unexpected reply from the worker.")
                }
            } catch {
                guard self.requestID == id else { return }
                self.phase = .failed("The local model could not answer: \(error.localizedDescription)")
            }
        }
    }

    private func finish(_ a: AnswerResponse) {
        response = a
        text = a.text
        phase = .done
        if !a.refused { history = Array((history + [AnswerTurn(question: question, answer: a.text)]).suffix(AskFollowUp.maxTurns)) }
    }

    /// The panel closed: the next question starts a new conversation.
    func endSession() {
        cancel()
        history = []
    }

    /// Esc, a new question, or closing the panel.
    func cancel() {
        task?.cancel()
        task = nil
        if let id = requestID, isWorking { worker?.cancel(JobID(id)) }
        requestID = nil
        if isWorking { phase = .idle }
    }

    func reset() {
        cancel()
        history = []
        phase = .idle; question = ""; text = ""; response = nil; passages = []
    }

    #if DEBUG
    /// ui-render: show a finished answer without the model.
    func showForRender(question: String, passages: [Passage], response: AnswerResponse?, phase: Phase, acrossMeetings: Bool, history: [AnswerTurn] = []) {
        self.history = history
        self.question = question; self.passages = passages; self.response = response; self.text = response?.text ?? ""
        self.phase = phase; self.acrossMeetings = acrossMeetings
    }
    #endif
}
