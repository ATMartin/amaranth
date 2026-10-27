import Foundation
import Domain
import DomainFixtures
import Storage
import Presentation

/// `Amaranth --self-test ask-worker`: one “ask anything” question end to end through the real XPC worker and the
/// installed notes model (T54), on a temporary library with the fixture meetings. Checks that the answer streams, cites
/// a passage of the asked meeting, and that a question the meeting can't answer is refused. Needs the model pack.
enum AskWorkerSelfTest {
    @MainActor static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-ask-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard ModelSetupModel.isReady(), let store = try? MeetingStore(root: root) else {
            SelfTest.log(["step": "setup", "error": "model pack not installed or store failed"]); return false
        }
        let f = Fixtures.twoSourceConversation
        do {
            try store.upsertMeeting(f.meeting)
            if let t = f.transcript { _ = try store.publishTranscript(t) }
            if let s = f.summary { _ = try store.publishSummary(s) }
        } catch { SelfTest.log(["step": "fixtures", "error": "\(error)"]); return false }
        let worker = WorkerClient()
        let answers = AnswerModel(store: store, worker: worker)
        answers.modelReady = { true }
        var ok = true
        for (question, expectAnswer) in [("When will they ship, and what is still missing?", true), ("What did they decide about the office lease?", false)] {
            var streamed = 0, last = ""
            let t0 = ContinuousClock.now
            answers.ask(question, in: f.meeting.id)
            for _ in 0..<1200 {
                try? await Task.sleep(for: .milliseconds(50))
                if answers.phase == .streaming, answers.text != last { streamed += 1; last = answers.text }
                if case .done = answers.phase { break }
                if case .failed = answers.phase { break }
            }
            let r = answers.response
            let cited = answers.citedPassages
            let pass = expectAnswer
                ? (r?.refused == false && !cited.isEmpty && cited.allSatisfy { $0.meetingID == f.meeting.id } && streamed > 1)
                : (r?.refused == true || r?.confidence == .low)
            SelfTest.log(["step": "ask", "question": question, "phase": "\(answers.phase)", "answer": answers.text,
                          "citations": cited.map { AskPassages.label($0, acrossMeetings: false) }.joined(separator: ", "),
                          "streamedUpdates": "\(streamed)", "firstTextSeconds": r?.firstTextSeconds.map { String(format: "%.2f", $0) } ?? "-",
                          "workerSeconds": r.map { String(format: "%.2f", $0.totalSeconds) } ?? "-",
                          "wallSeconds": String(format: "%.2f", Perf.seconds(since: t0)), "checker": r?.checkerNote ?? "-", "ok": "\(pass)"])
            if !pass { ok = false }
        }
        return ok
    }
}
