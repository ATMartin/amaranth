import SwiftUI
import AppKit
import Domain
import Storage
import Presentation
import DomainFixtures
import Models

/// `Amaranth --self-test ui-render-ask --render-dir <dir>` (T115/T116): renders the Ask pane's contextual states —
/// the loading graphic at each stage (animated and Reduce Motion), waiting, streaming, a cited answer with notes and the
/// passages read, clarification, no evidence, timeout, stale and unavailable — in light and dark. Also checks that the
/// loading view appears within one frame of `ask()` and that cancel stops it at once.
enum AskRenderSelfTest {
    @MainActor static func run(outputDirectory: URL?) async -> Bool {
        #if !DEBUG
        SelfTest.log(["step": "setup", "error": "Debug builds only"]); return false
        #else
        let out = outputDirectory ?? FileManager.default.temporaryDirectory.appending(path: "ask-render-\(UUID())")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-askrender-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = try? MeetingStore(root: root) else { return false }
        let f = Fixtures.twoSourceConversation
        try? store.upsertMeeting(f.meeting)
        if let t = f.transcript { _ = try? store.publishTranscript(t) }
        let library = LibraryModel(store: store)
        let models = ModelSetupModel()
        let passages = (try? Retriever(store: store).search("When will they ship?", in: f.meeting.id)) ?? []
        var ok = !passages.isEmpty
        func render<V: View>(_ v: V, _ name: String, appearance: NSAppearance, size: CGSize = CGSize(width: 280, height: 420)) {
            let view = NSHostingView(rootView: v.environment(library).environment(models).frame(width: size.width, height: size.height).background(Color.canvas))
            view.appearance = appearance
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance; window.contentView = view
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
        }
        let answers = AnswerModel(store: store, worker: nil)
        let notes = ["Searched meetings from Mon Oct 26 to Sun Nov 1 (“last week”).", "Still getting 28 of 40 meetings ready for search; until then they're only matched by their exact words."]
        let done = AnswerResponse(text: "Dana could pick it up once Northgate wraps; nothing was confirmed yet.", citations: [1], confidence: .high, refused: false,
                                  promptTokens: 0, generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0)
        for (appName, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            for stage in [AskStage.preparing, .searching, .reading, .answering] {
                render(AskLoadingView(stage: stage, waitingReason: nil, started: Date(), cancel: {}).padding(), "loading-\(stage.rawValue)-\(appName)", appearance: appearance, size: CGSize(width: 280, height: 80))
                render(AskLoadingView(stage: stage, waitingReason: nil, started: Date(), cancel: {}).environment(\.stillLoader, true).padding(),
                       "loading-\(stage.rawValue)-reduce-motion-\(appName)", appearance: appearance, size: CGSize(width: 280, height: 80))
            }
            let states: [(String, AnswerModel.Phase, AnswerResponse?)] = [
                ("waiting", .waiting("Waiting for transcription to finish…"), nil), ("streaming", .streaming, nil), ("done", .done, done),
                ("clarification", .clarification("Which Andrew do you mean? There are speakers named “Andrew” and “Andrew Kim” in these meetings. Ask again with the full name."), nil),
                ("no-evidence", .noEvidence("I couldn't find that in the meetings searched."), nil), ("timed-out", .timedOut, nil), ("stale", .stale, nil),
                ("unavailable-recording", .unavailable("Answers are paused while recording, so the recording keeps the Mac's full attention. Ask again when it ends; exact word matches are below."), nil)]
            for (name, phase, response) in states {
                answers.showForRender(question: "Who can staff the Trane project?", passages: passages, response: response, phase: phase, acrossMeetings: true, notes: notes)
                if phase == .streaming { answers.showForRender(question: "Who can staff the Trane project?", passages: passages, response: nil, phase: .streaming, acrossMeetings: true) }
                render(ScrollView { AnswerSection(answers: answers) }, "answer-\(name)-\(appName)", appearance: appearance)
            }
        }
        // Model readiness: without the local models or the search model the pane is dimmed and inert with the notice on
        // top; Settings → Models lists every model with its state. Rendered from forced states (the models root is not read).
        let packID = models.pack?.id ?? "pack", packVersion = models.pack?.version ?? "0"
        let readiness: [(String, ModelSetupModel.Status, Bool)] = [
            ("no-models", .recordOnly(reason: "Models are not installed. Recording works; transcripts and notes need the model pack."), false),
            ("search-missing", .ready(packID: packID, version: "0.1.1"), false),
            ("installing", .installing(InstallProgress(phase: .downloading, bytesDone: 260_000_000, bytesTotal: 639_000_000)), false),
            ("ready", .ready(packID: packID, version: packVersion), true)]
        for (appName, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            for (name, status, search) in readiness {
                models.showForRender(status, searchInstalled: search)
                render(AskPane(), "pane-\(name)-\(appName)", appearance: appearance, size: CGSize(width: 300, height: 520))
                render(ModelSetupView(model: models).frame(maxHeight: .infinity, alignment: .top), "settings-models-\(name)-\(appName)", appearance: appearance,
                       size: CGSize(width: 560, height: 640))
            }
        }
        models.showForRender(.ready(packID: packID, version: "0.1.1"), searchInstalled: false)
        let gated = !models.askReady && models.searchModelMissing && models.pendingDownloadBytes == models.searchModelBytes
        models.showForRender(.ready(packID: packID, version: packVersion), searchInstalled: true)
        let open = models.askReady && !models.searchModelMissing
        SelfTest.log(["step": "ask-readiness", "gatedWithoutSearch": "\(gated)", "openWithSearch": "\(open)"])
        ok = ok && gated && open
        // Feedback timing: ask() shows the loading state synchronously; cancel stops it synchronously.
        let live = AnswerModel(store: store, worker: nil)
        live.modelReady = { true }
        live.searchReady = { true }
        let t0 = ContinuousClock.now
        live.ask("When will they ship?", in: f.meeting.id)
        let feedback = Perf.seconds(since: t0)
        let shown = { if case .working = live.phase { true } else if case .unavailable = live.phase { true } else { false } }()
        try? await Task.sleep(for: .milliseconds(30))
        let t1 = ContinuousClock.now
        live.cancel()
        let cancelAck = Perf.seconds(since: t1)
        let stopped = !live.isWorking
        let timingOK = shown && feedback < ContextualLimits.feedbackWithin && stopped && cancelAck < ContextualLimits.cancelAcknowledgedWithin
        SelfTest.log(["step": "ask-render", "dir": out.path, "feedbackSeconds": String(format: "%.4f", feedback), "cancelAckSeconds": String(format: "%.4f", cancelAck), "ok": "\(timingOK)"])
        ok = ok && timingOK
        return ok
        #endif
    }
}
