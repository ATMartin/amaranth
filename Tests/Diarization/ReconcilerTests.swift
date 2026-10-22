import Foundation
import Testing
import Domain

/// Builders for synthetic ASR revisions and diarization results.
enum Build {
    static let producer = ProducerInfo(component: "test", configHash: "t")

    static func asr(_ words: [(String, Double, Double, SourceKind)]) -> TranscriptRevision {
        let ws = words.enumerated().map { i, w in
            Word(id: WordID("w\(i)"), text: w.0, interval: .seconds(w.1, w.2), source: w.3)
        }
        let segs = SourceKind.allCases.compactMap { src -> TranscriptSegment? in
            let mine = ws.filter { $0.source == src }
            guard let f = mine.first, let l = mine.last else { return nil }
            return TranscriptSegment(id: TranscriptSegmentID("s-\(src.rawValue)"), source: src, interval: SessionInterval(unchecked: f.interval.start, l.interval.end), words: mine)
        }
        return TranscriptRevision(id: RevisionID("asr-1"), meetingID: MeetingID("m"), kind: .final, stage: .asr, createdAt: Date(),
                                  producer: producer, segments: segs, coverage: [])
    }

    static func diar(_ turns: [(Double, Double, String)], source: SourceKind = .systemOutput, id: String = "d1") -> DiarizationResult {
        let ts = turns.map { SpeakerTurn(interval: .seconds($0.0, $0.1), source: source, cluster: ClusterID($0.2)) }
        var clusters: [ClusterID] = []
        for t in ts where !clusters.contains(t.cluster) { clusters.append(t.cluster) }
        // Overlaps: any pair of turns with different clusters that intersect.
        var ov: [SessionInterval] = []
        for a in ts { for b in ts where a.cluster < b.cluster { if let i = a.interval.intersection(b.interval) { ov.append(i) } } }
        return DiarizationResult(id: RevisionID(id), meetingID: MeetingID("m"), source: source, producer: producer,
                                 clusters: clusters, turns: ts, overlaps: ov)
    }
}

@Suite("Speaker reconciliation")
struct ReconcilerTests {
    let map = SourceMap(epochs: [], events: [])

    @Test func attributesByIntersectionAndAbstainsHonestly() throws {
        let asr = Build.asr([("hello", 1.0, 1.4, .systemOutput), ("there", 1.5, 1.9, .systemOutput),   // A
                             ("yes", 5.0, 5.3, .systemOutput),                                         // A+B overlap
                             ("mm", 9.0, 9.2, .systemOutput),                                          // no turn
                             ("right", 12.0, 12.4, .systemOutput)])                                    // near tie
        // "right" is only partly covered on each side (25 % vs 20 %): a near tie, not an overlap.
        let d = Build.diar([(0, 3, "A"), (4.9, 5.4, "A"), (4.95, 5.5, "B"), (11.0, 12.1, "A"), (12.32, 13, "B")])
        let r = try MeetingReconciler().combine(asr, diarization: [d], sourceMap: map, edits: [])
        let w = Dictionary(uniqueKeysWithValues: r.revision.allWords.map { ($0.text, $0) })
        let a = r.revision.speakers.first { $0.label == "Speaker 1" }!.id
        #expect(w["hello"]!.speaker == .speaker(a) && w["there"]!.speaker == .speaker(a))
        guard case .multiple(let both) = w["yes"]!.speaker else { Issue.record("overlap must be .multiple"); return }
        #expect(both.count == 2 && w["yes"]!.flags.contains(.overlap))
        #expect(w["mm"]!.speaker == .unknown, "no evidence → unknown, not guessed")
        #expect(w["right"]!.flags.contains(.uncertainSpeaker))
        #expect(w["right"]!.candidates.count == 2 && w["right"]!.candidates.allSatisfy { $0.rawScore != nil })
        #expect(r.revision.speakers.allSatisfy { $0.displayName == nil }, "acoustic grouping never invents names")
        // Segments split at speaker changes.
        #expect(r.revision.segments.allSatisfy { seg in seg.words.allSatisfy { $0.speaker == seg.speaker } })
    }

    /// Exact ties used to follow dictionary order, which is seeded per process: the same inputs gave a different
    /// speaker (or `.multiple` order) on each run. Ties now follow first-seen order (diarization, then turn order).
    @Test func tiesAreBrokenDeterministically() throws {
        let asr = Build.asr([("both", 5.0, 5.2, .systemOutput), ("half", 8.0, 8.4, .systemOutput)])
        // "both" lies fully inside an A turn and a B turn; "half" is covered 50/50 by A and B (one turn each side).
        let d = Build.diar([(1, 4, "C"), (4.9, 5.5, "A"), (4.95, 5.6, "B"), (7.0, 8.2, "A"), (8.2, 9, "B")])
        let r = try MeetingReconciler().combine(asr, diarization: [d], sourceMap: map, edits: [])
        let w = Dictionary(uniqueKeysWithValues: r.revision.allWords.map { ($0.text, $0) })
        let idOf = Dictionary(uniqueKeysWithValues: r.revision.speakers.flatMap { s in s.clusters.map { ($0.cluster, s.id) } })
        #expect(w["both"]!.speaker == .multiple([idOf[ClusterID("A")]!, idOf[ClusterID("B")]!]))
        #expect(w["half"]!.speaker == .multiple([idOf[ClusterID("A")]!, idOf[ClusterID("B")]!]))
        #expect(w["half"]!.candidates.map(\.speaker) == [idOf[ClusterID("A")]!, idOf[ClusterID("B")]!])
    }

    @Test func personalMicProposesOneLocalSpeakerAndRoomModeDiarizesMic() throws {
        let asr = Build.asr([("we", 1, 1.3, .microphone), ("agree", 1.4, 1.8, .microphone), ("ok", 3, 3.3, .systemOutput)])
        let sys = Build.diar([(2.5, 4, "R")])
        let personal = try MeetingReconciler(microphoneMode: .personal).combine(asr, diarization: [sys], sourceMap: map, edits: [])
        let micWords = personal.revision.allWords.filter { $0.source == .microphone }
        let micSpeaker = try #require(personal.revision.speakers.first { $0.primarySource == .microphone })
        #expect(micWords.allSatisfy { $0.speaker == .speaker(micSpeaker.id) })
        #expect(micSpeaker.displayName == nil && micSpeaker.label.hasPrefix("Speaker "))
        // Room mode: two people share the mic; mic diarization separates them.
        let micDiar = Build.diar([(0.9, 1.35, "M1"), (1.35, 2, "M2")], source: .microphone, id: "d2")
        let room = try MeetingReconciler(microphoneMode: .room).combine(asr, diarization: [sys, micDiar], sourceMap: map, edits: [])
        let ids = Set(room.revision.allWords.filter { $0.source == .microphone }.flatMap(\.speaker.speakerIDs))
        #expect(ids.count == 2, "a source never guarantees one human")
    }

    @Test func echoIsFlaggedReversiblyAndRealInterruptionsSurvive() throws {
        // System says a sentence; the mic picks it up 0.12 s later (speakerphone bleed). The local user also interrupts.
        var spec: [(String, Double, Double, SourceKind)] = []
        let sentence = ["the", "build", "is", "green", "today"]
        for (i, t) in sentence.enumerated() {
            spec.append((t, 10 + Double(i) * 0.4, 10.3 + Double(i) * 0.4, .systemOutput))
            spec.append((t, 10.12 + Double(i) * 0.4, 10.42 + Double(i) * 0.4, .microphone))
        }
        spec += [("wait", 11.0, 11.3, .microphone), ("stop", 11.35, 11.6, .microphone)] // genuine interruption during playback
        spec += [("the", 20, 20.2, .microphone)]                                       // isolated common word, no echo run
        let asr = Build.asr(spec)
        let r = try MeetingReconciler(echoDelay: 0.12).combine(asr, diarization: [Build.diar([(9, 13, "R")])], sourceMap: map, edits: [])
        let mic = r.revision.allWords.filter { $0.source == .microphone }
        #expect(mic.count == sentence.count + 3, "no word is removed")
        let echoed = mic.filter { $0.flags.contains(.probableEchoDuplicate) }.map(\.text)
        #expect(echoed == sentence)
        #expect(!mic.first { $0.text == "wait" }!.flags.contains(.probableEchoDuplicate))
        #expect(!mic.first { $0.text == "the" && $0.interval.start == .seconds(20) }!.flags.contains(.probableEchoDuplicate))
        // Without a measured echo delay nothing is flagged (headphones).
        let none = try MeetingReconciler(echoDelay: nil).combine(asr, diarization: [], sourceMap: map, edits: [])
        #expect(!none.revision.allWords.contains { $0.flags.contains(.probableEchoDuplicate) })
    }

    @Test func eightSpeakerShortTurnsKeepUncertaintyAndNoNames() throws {
        var words: [(String, Double, Double, SourceKind)] = []
        var turns: [(Double, Double, String)] = []
        for i in 0..<40 {
            let t = Double(i) * 0.7
            words.append(("w\(i)", t + 0.05, t + 0.35, .systemOutput))
            turns.append((t, t + 0.4, "S\(i % 8)"))
            if i % 5 == 0 { turns.append((t + 0.1, t + 0.45, "S\((i + 3) % 8)")) } // frequent crosstalk
        }
        let r = try MeetingReconciler().combine(Build.asr(words), diarization: [Build.diar(turns)], sourceMap: map, edits: [])
        #expect(r.revision.speakers.count == 8)
        #expect(r.revision.speakers.allSatisfy { $0.displayName == nil })
        let flagged = r.revision.allWords.filter { $0.flags.contains(.overlap) || $0.flags.contains(.uncertainSpeaker) || $0.speaker.speakerIDs.count > 1 }
        #expect(flagged.count >= 8, "crosstalk turns retain uncertainty")
    }

    @Test func editsSurviveReprocessingOrAskForReview() throws {
        let asr = Build.asr([("plan", 1, 1.3, .systemOutput), ("ahead", 1.4, 1.8, .systemOutput),
                             ("fine", 4, 4.3, .systemOutput), ("thanks", 4.4, 4.8, .systemOutput)])
        let first = try MeetingReconciler().combine(asr, diarization: [Build.diar([(0, 2, "A"), (3.5, 5, "B")])], sourceMap: map, edits: [])
        let r1 = first.revision
        let s1 = r1.speakers[0].id, s2 = r1.speakers[1].id
        let fine = r1.allWords.first { $0.text == "fine" }!.id, thanks = r1.allWords.first { $0.text == "thanks" }!.id
        let edits = [
            UserEdit(meetingID: MeetingID("m"), baseRevisionID: r1.id, sequence: 1, createdAt: Date(), operation: .renameSpeaker(s1, displayName: "Dana")),
            UserEdit(meetingID: MeetingID("m"), baseRevisionID: r1.id, sequence: 2, createdAt: Date(),
                     operation: .reassign(WordRange(revisionID: r1.id, first: fine, last: thanks), to: .new(SpeakerID("new-1"), label: "Speaker 3"))),
            UserEdit(meetingID: MeetingID("m"), baseRevisionID: r1.id, sequence: 3, createdAt: Date(), operation: .renameSpeaker(s2, displayName: "Lee")),
        ]
        // Reprocess: new diarization run with different cluster IDs (same structure) and a new ASR revision with new word IDs.
        var asr2 = asr
        asr2.id = RevisionID("asr-2")
        asr2.segments = asr.segments.map { seg in var s = seg; s.words = s.words.map { var w = $0; w.id = WordID("n-" + $0.id.rawValue); return w }; return s }
        let second = try MeetingReconciler(previous: r1).combine(asr2, diarization: [Build.diar([(0, 2, "X"), (3.5, 5, "Y")], id: "d9")],
                                                                  sourceMap: map, edits: edits)
        let r2 = second.revision
        #expect(r2.speakers.contains { $0.displayName == "Dana" }, "rename mapped onto the re-clustered speaker")
        let fineNew = r2.allWords.first { $0.text == "fine" }!
        #expect(fineNew.speaker == .speaker(SpeakerID("new-1")), "reassignment rebased by time + text")
        #expect(second.editsNeedingReview.isEmpty)
        // If reprocessing changed the words, an automatic rebase is not attempted: the edit asks for review.
        var asr3 = asr2
        asr3.id = RevisionID("asr-3")
        asr3.segments = asr2.segments.map { seg in var s = seg; s.words = s.words.map { var w = $0; if w.text == "fine" { w.text = "find" }; return w }; return s }
        let third = try MeetingReconciler(previous: r1).combine(asr3, diarization: [Build.diar([(0, 2, "X"), (3.5, 5, "Y")], id: "d9")],
                                                                 sourceMap: map, edits: edits)
        #expect(third.editsNeedingReview.map(\.sequence) == [2])
        #expect(third.editsNeedingReview.allSatisfy { $0.conflict == .needsReview })
        #expect(third.revision.speakers.contains { $0.displayName == "Dana" }, "unaffected edits still apply")
    }
}
