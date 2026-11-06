import Foundation
import Testing
@testable import Storage
import Domain
import DomainFixtures

/// T111 (spec 0010): the derived contextual index follows current content in the same transaction; vectors are guarded.
@Suite("Contextual index storage (T111)", .serialized)
struct ContextIndexTests {
    static let producer = FakeEncoder.producer

    func embedAll(_ store: MeetingStore) throws -> Int {
        let pending = try store.pendingContextChunks(producer: Self.producer.id, limit: 10_000)
        return try store.publishContextVectors(pending.map { ($0.contentHash, FakeEncoder.vector($0.text)) }, producer: Self.producer)
    }

    @Test func hiddenWordsNeverEnterChunksAndEditsRewriteThemInTheSameTransaction() throws {
        var f = try AccessFixture()
        let before = try f.store.contextChunks(f.meeting)
        #expect(!before.isEmpty)
        #expect(before.contains { $0.text.contains("HIDDENCORRECT") }, "before the edit the word is current")
        _ = try embedAll(f.store)
        try f.applyUserEdits()
        let after = try f.store.contextChunks(f.meeting)
        let all = after.map(\.text).joined(separator: "\n")
        for marker in AccessFixture.hidden.prefix(4) { #expect(!all.contains(marker), "\(marker) must not be in a chunk") }
        #expect(all.contains("Dana: "), "speaker renames reach chunk text")
        // Every span resolves to a current word of the current (edited) transcript.
        let tr = try #require(try f.store.transcriptRevision(f.transcript.id)).applyingTextEdits(try f.store.edits(f.meeting))
        let current = Set(tr.segments.flatMap { $0.words.map(\.id) })
        #expect(after.allSatisfy { $0.spans.allSatisfy { current.contains($0.firstWord) && current.contains($0.lastWord) } })
        // Vectors of text that no longer exists are gone, and can't be published again.
        let stale = Set(before.map(\.contentHash)).subtracting(after.map(\.contentHash))
        #expect(!stale.isEmpty)
        let n = try f.store.publishContextVectors(stale.map { ($0, FakeEncoder.vector("x")) }, producer: Self.producer)
        #expect(n == 0, "an old job can't restore edited-away text")
        #expect(try f.store.contextIndexStats().vectors == Set(before.map(\.contentHash)).intersection(after.map(\.contentHash)).count)
    }

    @Test func unchangedChunksKeepVectorsAndGenerationsBump() throws {
        let lib = try RetrievalLibrary()
        let lines = (0..<80).map { "line number \($0) about the quarterly plan and some other words here" }
        let m = try lib.meeting("Long", lines: lines)
        #expect(try embedAll(lib.store) > 3)
        let g0 = try lib.store.contextGenerations([m])[m]
        let chunks = try lib.store.contextChunks(m)
        // Correct a word in the last line: only the last chunk(s) need new vectors.
        let tr = try #require(try lib.store.meeting(m)?.currentTranscriptRevisionID)
        try lib.store.appendEdit(UserEdit(meetingID: m, baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                          operation: .correctText(WordRange(revisionID: tr, first: WordID("79-0"), last: WordID("79-0")), replacement: "LAST")))
        #expect(try lib.store.contextGenerations([m])[m] == g0! + 1)
        let pending = try lib.store.pendingContextChunks(producer: Self.producer.id, limit: 100)
        #expect(pending.count == 1 && pending[0].text.contains("LAST"))
        #expect(try lib.store.contextChunks(m).count == chunks.count)
        #expect(try lib.store.contextCoverage(ContextFilter(meetings: [m]), producer: Self.producer.id).meetingsIndexed == 0)
        _ = try embedAll(lib.store)
        let cov = try lib.store.contextCoverage(ContextFilter(meetings: [m]), producer: Self.producer.id)
        #expect(cov.complete && cov.chunks == cov.chunksEmbedded)
    }

    @Test func scopeFiltersApplyBeforeScoringAndDeletionRemovesEverything() throws {
        let lib = try RetrievalLibrary()
        let folder = try lib.store.createFolder(name: "Clients").id
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try lib.meeting("A", lines: ["the budget for the offsite is fifteen hundred euros"], folder: folder, start: t0)
        let b = try lib.meeting("B", lines: ["the budget for the offsite is fifteen hundred euros"], start: t0.addingTimeInterval(86_400 * 7))
        let c = try lib.meeting("C", lines: ["completely unrelated chatter about lunch"], start: t0.addingTimeInterval(86_400 * 14))
        _ = try embedAll(lib.store)
        let q = FakeEncoder.vector("offsite budget euros")
        func hits(_ f: ContextFilter) throws -> [MeetingID] { try lib.store.vectorSearch(q, producer: Self.producer, filter: f, k: 10).map(\.meetingID) }
        #expect(Set(try hits(ContextFilter())) == [a, b, c])
        #expect(try hits(ContextFilter(folder: folder)) == [a])
        #expect(try hits(ContextFilter(meetings: [b, c])).first == b)
        #expect(try hits(ContextFilter(meetings: [])) == [])
        #expect(Set(try hits(ContextFilter(start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(86_400 * 8)))) == [b])
        // Wrong producer/dimensions never mix.
        var other = Self.producer; other.dimensions = 32
        #expect(try lib.store.vectorSearch(Array(q.prefix(32)), producer: other, filter: ContextFilter(), k: 10).isEmpty)
        #expect(try lib.store.publishContextVectors([(try lib.store.contextChunks(a)[0].contentHash, q)], producer: other) == 0, "64-d vector rejected for a 32-d producer")
        // Folder move: filter follows it immediately (no re-embed).
        try lib.store.moveMeeting(b, to: folder)
        #expect(Set(try hits(ContextFilter(folder: folder))) == [a, b])
        // Audio-only deletion keeps retrieval.
        try lib.store.deleteAudio(c)
        #expect(try hits(ContextFilter(meetings: [c])) == [c])
        // Tombstone: gone from results at once; purge removes chunks and vectors (b shares a's text, so that vector stays).
        try lib.store.tombstone(a)
        #expect(!(try hits(ContextFilter())).contains(a))
        try lib.store.purgeMeeting(a)
        #expect(try lib.store.contextChunks(a).isEmpty && (try lib.store.contextGenerations([a])).isEmpty)
        #expect(try lib.store.vectorSearch(q, producer: Self.producer, filter: ContextFilter(meetings: [b]), k: 1).count == 1)
        try lib.store.tombstone(c); try lib.store.purgeMeeting(c)
        let stats = try lib.store.contextIndexStats()
        #expect(stats.chunks == 1 && stats.vectors == 1)
    }

    @Test func failuresAreCountedAndPendingSkipsThemUntilCleared() throws {
        let lib = try RetrievalLibrary()
        _ = try lib.meeting("A", lines: ["alpha beta gamma"])
        let p = try lib.store.pendingContextChunks(producer: Self.producer.id, limit: 10)
        for _ in 0..<3 { try lib.store.recordContextFailure(p.map(\.contentHash), producer: Self.producer.id, error: "boom") }
        #expect(try lib.store.pendingContextChunks(producer: Self.producer.id, limit: 10).isEmpty)
        #expect(try lib.store.contextCoverage(ContextFilter(), producer: Self.producer.id).chunksEmbedded == 0)
        try lib.store.clearContextFailures(producer: Self.producer.id)
        #expect(try lib.store.pendingContextChunks(producer: Self.producer.id, limit: 10).count == 1)
    }

    @Test func v6LibraryMigratesWithChunksAndNoContentLoss() throws {
        let lib = try RetrievalLibrary()
        let m = try lib.meeting("Old", lines: ["we kept the old transcript", "and its second line"], notes: ["a note"])
        let transcriptBefore = try lib.store.meeting(m)?.currentTranscriptRevisionID
        // Simulate a v6 library: drop the v7 tables and the version.
        let path = lib.root.appending(path: "amaranth.sqlite").path
        do {
            let db = try SQLiteDB(path: path)
            try db.exec("DROP TABLE context_chunks; DROP TABLE context_vectors; DROP TABLE context_failures; DROP TABLE context_meeting_state; PRAGMA user_version = 6;")
        }
        let reopened = try MeetingStore(root: lib.root)
        #expect(try reopened.meeting(m)?.currentTranscriptRevisionID == transcriptBefore)
        #expect(try reopened.currentNotesDocument(m)?.blocks.contains { $0.text == "a note" } == true)
        let chunks = try reopened.contextChunks(m)
        #expect(chunks.count == 1 && chunks[0].text.contains("we kept the old transcript"))
        #expect(try reopened.contextIndexStats().vectors == 0, "migration never embeds")
    }
}

@Suite("User attribution in the index (T119)")
struct LocalUserIndexTests {
    /// One meeting whose mic words belong to the personal-mic speaker and whose system words to Speaker 2.
    static func micMeeting(_ lib: RetrievalLibrary) throws -> MeetingID {
        let m = try lib.meeting("Sync", lines: [])
        let mic = SpeakerID("spk-abcd1234-mic"), other = SpeakerID("spk-abcd1234-1")
        func seg(_ i: Int, _ text: String, _ src: SourceKind, _ spk: SpeakerID) -> TranscriptSegment {
            let words = text.split(separator: " ").enumerated().map { j, w in
                Word(id: WordID("\(i)-\(j)"), text: String(w), interval: .seconds(Double(i) * 5 + Double(j) * 0.2, Double(i) * 5 + Double(j) * 0.2 + 0.15),
                     source: src, speaker: .speaker(spk))
            }
            return TranscriptSegment(id: TranscriptSegmentID("seg\(i)"), source: src, interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end),
                                     words: words, speaker: .speaker(spk))
        }
        try lib.store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: Date(), producer: ProducerInfo(component: "t", configHash: "t"),
                                                           segments: [seg(0, "I will send the deck", .microphone, mic), seg(1, "thanks see you", .systemOutput, other)],
                                                           coverage: [], speakers: [Speaker(id: mic, label: "Speaker 2", primarySource: .microphone),
                                                                                    Speaker(id: other, label: "Speaker 1", primarySource: .systemOutput)]))
        return m
    }

    @Test func micSpeakerIsIndexedUnderTheUsersNameAndMarked() throws {
        let lib = try RetrievalLibrary()
        let m = try Self.micMeeting(lib)
        let dir = try lib.store.nameDirectory(ContextFilter())
        #expect(dir.localUserSpeakers == [Speaker.localUserName: [m]])
        #expect(dir.speakers[Speaker.localUserName] == [m] && dir.speakers["Speaker 1"] == nil)
        #expect(try lib.store.contextChunks(m).contains { $0.text.contains(Speaker.localUserName) })
    }

    @Test func v7LibraryIsReindexedWithTheName() throws {
        let lib = try RetrievalLibrary()
        let m = try Self.micMeeting(lib)
        do {
            let db = try SQLiteDB(path: lib.root.appending(path: "amaranth.sqlite").path)
            try db.exec("DELETE FROM search_index; DELETE FROM context_chunks; PRAGMA user_version = 7;")
        }
        let reopened = try MeetingStore(root: lib.root)
        #expect(try reopened.nameDirectory(ContextFilter()).localUserSpeakers == [Speaker.localUserName: [m]])
        #expect(try reopened.contextChunks(m).contains { $0.text.contains(Speaker.localUserName) })
    }
}
