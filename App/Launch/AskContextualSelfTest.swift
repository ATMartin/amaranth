import Foundation
import Contextual
import Domain
import Models
import Presentation
import Storage

/// `Amaranth --self-test ask-contextual --model-dir <ModelStore> --models-root <dir>` (Debug, T115/T116): contextual Ask
/// end to end through the packaged XPC worker with the real notes model and encoder, from a verified install in a
/// models root of its own (the user's pack is never touched; reused across runs). A temporary synthetic library is
/// indexed by the real indexer; then questions are asked through `AnswerModel` exactly as the Ask pane does, each timed
/// from submission to its terminal state (the first one with a freshly launched worker: models load cold). Then the
/// cited line is corrected (ask again: the answer follows the edit), and the meeting is deleted (ask again: it's gone).
enum AskContextualSelfTest {
    @MainActor static func run(modelDirectory: URL?, modelsRoot: URL?) async -> Bool {
        #if DEBUG
        guard let dir = modelDirectory, let mroot = modelsRoot, let bundled = ModelSetupModel.bundledPack() else {
            SelfTest.log(["step": "setup", "error": "--model-dir and --models-root are required"]); return false
        }
        let manifests = bundled.manifests.filter { $0.role == .textEmbedding || $0.role == .summary }
        do {
            let t0 = ContinuousClock.now
            try await ModelInstaller(store: ModelPackStore(root: mroot)).install(ModelPack(id: "selftest-ask", version: bundled.version, profile: bundled.profile, manifests: manifests),
                                                                                 from: DirectoryModelSource(root: dir))
            SelfTest.log(["step": "install", "seconds": String(format: "%.1f", Perf.seconds(since: t0)), "ok": "true"])
        } catch { SelfTest.log(["step": "install", "error": "\(error)"]); return false }
        let defaults = UserDefaults.standard
        defaults.set(mroot.path, forKey: "debugModelsRoot")
        defer { defaults.removeObject(forKey: "debugModelsRoot") }
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-askctx-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = try? MeetingStore(root: root), let ids = try? seed(store) else { SelfTest.log(["step": "seed", "error": "failed"]); return false }
        let worker = WorkerClient()
        let indexer = ContextIndexer(store: store, worker: worker, remember: false)
        indexer.start()
        let t0 = ContinuousClock.now
        while indexer.state != .ready, Perf.seconds(since: t0) < 120 { try? await Task.sleep(for: .milliseconds(100)) }
        SelfTest.log(["step": "index", "seconds": String(format: "%.1f", Perf.seconds(since: t0)), "chunks": "\(indexer.coverage.chunks)", "ok": "\(indexer.state == .ready)"])
        indexer.stop()
        let answers = AnswerModel(store: store, worker: worker)
        answers.modelReady = { true }
        answers.producer = { indexer.engine?.activeProducer }
        func ask(_ q: String, scope: MeetingID? = nil) async -> (phase: AnswerModel.Phase, seconds: Double, text: String, cited: [Passage], notes: [String]) {
            let t = ContinuousClock.now
            answers.ask(q, in: scope, force: true)
            while answers.isWorking, Perf.seconds(since: t) < 20 { try? await Task.sleep(for: .milliseconds(20)) }
            return (answers.phase, Perf.seconds(since: t), answers.text, answers.citedPassages, answers.notes)
        }
        var ok = true
        var results: [[String: String]] = []
        let questions: [(String, (AnswerModel.Phase, String, [Passage]) -> Bool)] = [
            ("Who could take on the Harrow rollout over the last week?", { p, t, c in p == .done && !c.isEmpty && t.lowercased().contains("lena") }),
            ("What did Marco propose for his next role last week?", { p, t, c in p == .done && t.lowercased().contains("team lead") }),
            ("What did I promise to send today?", { p, t, _ in p == .done && t.contains("Speaker") || { if case .clarification = p { true } else { false } }() }),
            ("Did we pick a final venue for the offsite?", { p, t, _ in p == .done && (t.lowercased().contains("reopen") || t.lowercased().contains("not final") || t.lowercased().contains("no final")) }),
        ]
        for (i, (q, check)) in questions.enumerated() {
            let r = await ask(q)
            let pass = check(r.phase, r.text, r.cited) && r.seconds <= ContextualLimits.deadline
            results.append(["q": q, "phase": "\(r.phase)", "seconds": String(format: "%.2f", r.seconds), "cold": "\(i == 0)", "answer": r.text, "notes": r.notes.joined(separator: " | "), "ok": "\(pass)"])
            SelfTest.log(["step": "ask", "q": q, "phase": "\(r.phase)", "seconds": String(format: "%.2f", r.seconds), "cold": "\(i == 0)", "answer": r.text,
                          "cited": r.cited.map { AskPassages.label($0, acrossMeetings: true) }.joined(separator: ", "), "notes": r.notes.joined(separator: " | "), "ok": "\(pass)"])
            if !pass { ok = false }
        }
        // Edit → ask: the corrected word is what the answer can use; the old one never comes back.
        let harrow = ids["harrow-2"]!
        if let tr = try? store.meeting(harrow)?.currentTranscriptRevisionID, let seg = try? store.transcriptRevision(tr)?.segments.first(where: { $0.words.contains { $0.text.hasPrefix("Lena") } }),
           let w = seg.words.first(where: { $0.text.hasPrefix("Lena") }) {
            try? store.appendEdit(UserEdit(meetingID: harrow, baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                           operation: .correctText(WordRange(revisionID: tr, first: w.id, last: w.id), replacement: "Priyanka's")))
        }
        let edited = await ask("Who could take on the Harrow rollout over the last week?")
        let editOK = edited.seconds <= ContextualLimits.deadline && !answers.passages.contains { p in p.meetingID == harrow && p.lines.contains { $0.text.contains("Lena") } }
            && answers.passages.contains { p in p.meetingID == harrow && p.lines.contains { $0.text.contains("Priyanka") } }
        SelfTest.log(["step": "edit-ask", "phase": "\(edited.phase)", "seconds": String(format: "%.2f", edited.seconds), "answer": edited.text, "ok": "\(editOK)"])
        // Delete → ask: nothing from the deleted meeting.
        try? store.tombstone(harrow)
        let deleted = await ask("Who could take on the Harrow rollout over the last week?")
        let deleteOK = deleted.seconds <= ContextualLimits.deadline && !deleted.cited.contains { $0.meetingID == harrow } && !answers.passages.contains { $0.meetingID == harrow }
        SelfTest.log(["step": "delete-ask", "phase": "\(deleted.phase)", "seconds": String(format: "%.2f", deleted.seconds), "answer": deleted.text, "ok": "\(deleteOK)"])
        return ok && editOK && deleteOK
        #else
        return false
        #endif
    }

    /// A small invented library (not from the evaluation sets): staffing over the last week, a proposal last week vs
    /// earlier, today's commitments (anonymous speakers), a decision that was reopened.
    static func seed(_ store: MeetingStore) throws -> [String: MeetingID] {
        let now = Date()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current; cal.firstWeekday = 2
        let thisMonday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let lastWeek = cal.date(byAdding: .day, value: -5, to: thisMonday)!.addingTimeInterval(10 * 3600)
        let threeWeeks = cal.date(byAdding: .day, value: -19, to: thisMonday)!.addingTimeInterval(10 * 3600)
        let today = cal.startOfDay(for: now).addingTimeInterval(60)
        let meetings: [(String, String, Date, [String], [(Int, String)])] = [
            ("harrow-1", "Delivery sync", now.addingTimeInterval(-3 * 86_400), ["Speaker 1", "Speaker 2"], [
                (0, "Okay, quick one on the Harrow rollout."), (1, "We're short a person for the data migration part."),
                (0, "Lena might be able to help once the billing work wraps, but nothing's confirmed."), (1, "Let's ask her manager."),
                (0, "Also the parking garage closes early on Friday.")]),
            ("harrow-2", "Resourcing check", now.addingTimeInterval(-1 * 86_400), ["Speaker 1", "Speaker 2"], [
                (0, "Update on Harrow staffing."), (1, "Lena's manager said yes, so she starts on the rollout Monday."),
                (0, "Great, and Tom is out, he's on the audit through December."), (1, "Okay.")]),
            ("career-1", "Marco 1:1", lastWeek, ["Speaker 1", "Marco"], [
                (0, "So what are you thinking for next year?"), (1, "Honestly I'd like to move into a team lead role and start managing people."),
                (0, "That makes sense, let's plan for it.")]),
            ("career-0", "Marco 1:1", threeWeeks, ["Speaker 1", "Marco"], [
                (1, "I think I want to get deeper into the database internals."), (0, "Okay, noted.")]),
            ("today-1", "Client call", today, ["Speaker 1", "Speaker 2"], [
                (0, "I'll send you the revised statement of work by Monday."), (1, "Great, and I'll check with our legal team on the clause."),
                (0, "Maybe we could also look at the timeline later.")]),
            ("venue-1", "Offsite planning", now.addingTimeInterval(-10 * 86_400), ["Speaker 1", "Speaker 2"], [
                (0, "We're going with the lakeside lodge for the offsite, that's final."), (1, "Booking it today.")]),
            ("venue-2", "Offsite follow-up", now.addingTimeInterval(-2 * 86_400), ["Speaker 1", "Speaker 2"], [
                (0, "The lodge doubled their price, so we're reopening the venue choice."), (1, "So nothing is booked until we compare again.")]),
        ]
        var ids: [String: MeetingID] = [:]
        for (key, title, start, speakers, lines) in meetings {
            let m = MeetingID(); ids[key] = m
            try store.upsertMeeting(Meeting(id: m, title: title, createdAt: start, clock: SessionClock(utcOrigin: start, timeZoneIdentifier: TimeZone.current.identifier, hostTimeOriginNanos: 0),
                                            captureState: .captured, duration: .seconds(60)))
            let sp = speakers.enumerated().map { Speaker(id: SpeakerID("\(key)-\($0.offset)"), label: "Speaker \($0.offset + 1)", displayName: $0.element.hasPrefix("Speaker") ? nil : $0.element) }
            var t = 0.0
            let segs = lines.enumerated().map { i, l -> TranscriptSegment in
                let who = SpeakerAssignment.speaker(sp[l.0].id)
                let words = l.1.split(separator: " ").enumerated().map { j, w in
                    Word(id: WordID("\(key)-\(i)-\(j)"), text: String(w), interval: .seconds(t + Double(j) * 0.3, t + Double(j) * 0.3 + 0.25), source: .systemOutput, speaker: who)
                }
                t += Double(words.count) * 0.3 + 0.5
                return TranscriptSegment(id: TranscriptSegmentID("\(key)-s\(i)"), source: .systemOutput, interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end),
                                         words: words, speaker: who)
            }
            try store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: start, producer: ProducerInfo(component: "selftest", configHash: "t"),
                                                           segments: segs, coverage: [], speakers: sp))
        }
        return ids
    }
}
