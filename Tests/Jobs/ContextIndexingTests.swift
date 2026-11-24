import Foundation
import Testing
@testable import ProcessingCore
import Storage
import Domain
import DomainFixtures

/// T112: background indexing is resumable, yields, and can never publish obsolete text.
@Suite("Contextual indexing engine (T112)", .serialized)
struct ContextIndexingTests {
    final class Box<T>: @unchecked Sendable { var value: T; let lock = NSLock(); init(_ v: T) { value = v }
        func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } } }

    static func library(meetings: Int = 3, lines: Int = 60) throws -> (MeetingStore, [MeetingID]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-ctxidx-\(UUID())")
        let store = try MeetingStore(root: root)
        var ids: [MeetingID] = []
        for k in 0..<meetings {
            let m = MeetingID(); ids.append(m)
            let start = Date(timeIntervalSince1970: 1_800_000_000 + Double(k) * 86_400)
            try store.upsertMeeting(Meeting(id: m, title: "M\(k)", createdAt: start, clock: SessionClock(utcOrigin: start, timeZoneIdentifier: "UTC", hostTimeOriginNanos: 0),
                                            captureState: .captured, duration: .seconds(60)))
            let spk = SpeakerID("s")
            let segs = (0..<lines).map { i in
                let words = "meeting \(k) line \(i) talks about plans and other things today".split(separator: " ").enumerated().map { j, w in
                    Word(id: WordID("\(k)-\(i)-\(j)"), text: String(w), interval: .seconds(Double(i) * 5 + Double(j) * 0.2, Double(i) * 5 + Double(j) * 0.2 + 0.1),
                         source: .systemOutput, speaker: .speaker(spk))
                }
                return TranscriptSegment(id: TranscriptSegmentID("\(k)-seg\(i)"), source: .systemOutput,
                                         interval: SessionInterval(unchecked: words.first!.interval.start, words.last!.interval.end), words: words, speaker: .speaker(spk))
            }
            try store.publishTranscript(TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: start, producer: ProducerInfo(component: "t", configHash: "t"),
                                                           segments: segs, coverage: [], speakers: [Speaker(id: spk, label: "Speaker 1")]))
        }
        return (store, ids)
    }

    static func fakeEmbed(_ producer: EncoderProducer = FakeEncoder.producer, before: (@Sendable ([String]) throws -> Void)? = nil)
        -> @Sendable (String, [String]) async throws -> EmbedResponse {
        { _, texts in
            try before?(texts)
            return EmbedResponse(producer: producer, vectors: EmbedResponse.pack(texts.map(FakeEncoder.vector)), seconds: 0, loaded: false)
        }
    }

    static func hooks(embed: @escaping @Sendable (String, [String]) async throws -> EmbedResponse = fakeEmbed(), pause: String? = nil,
                      available: Bool = true, revision: String = FakeEncoder.producer.revision, free: Int64? = nil,
                      cancel: @escaping @Sendable (String) -> Void = { _ in }) -> ContextIndexingEngine.Hooks {
        .init(embed: embed, cancel: cancel, pauseReason: { pause },
              installedEncoder: { available ? (revision, FakeEncoder.producer.weightsSHA256) : nil }, freeBytes: { free })
    }

    func drain(_ e: ContextIndexingEngine, max: Int = 100) async -> [ContextIndexingEngine.Step] {
        var steps: [ContextIndexingEngine.Step] = []
        for _ in 0..<max { let s = await e.step(); steps.append(s); if s == .idle { break } }
        return steps
    }

    @Test func backfillCompletesAndResumesIdempotentlyAfterRestart() async throws {
        let (store, _) = try Self.library()
        let total = try store.contextIndexStats().chunks
        let e1 = ContextIndexingEngine(store: store, hooks: Self.hooks(), producer: nil)
        #expect(await e1.step() == .indexed(min(total, ContextIndexingEngine.batchSize)))
        // "Restart": a new engine that remembers the producer continues; nothing is re-embedded.
        let calls = Box(0)
        let e2 = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: Self.fakeEmbed(before: { _ in calls.with { $0 += 1 } })), producer: e1.producer)
        let steps = await drain(e2)
        #expect(steps.last == .idle)
        let embedded = steps.reduce(0) { if case .indexed(let n) = $1 { $0 + n } else { $0 } }
        #expect(embedded == total - min(total, ContextIndexingEngine.batchSize))
        #expect(e2.coverage().complete)
        #expect(await e2.step() == .idle && calls.value == steps.count - 1)
    }

    @Test func pausedUnavailableAndLowDiskDoNoWork() async throws {
        let (store, _) = try Self.library(meetings: 1)
        #expect(await ContextIndexingEngine(store: store, hooks: Self.hooks(pause: "recording"), producer: nil).step() == .paused("recording"))
        if case .unavailable = await ContextIndexingEngine(store: store, hooks: Self.hooks(available: false), producer: nil).step() {} else { Issue.record("expected unavailable") }
        if case .paused = await ContextIndexingEngine(store: store, hooks: Self.hooks(free: 10), producer: nil).step() {} else { Issue.record("expected low-disk pause") }
        #expect(try store.contextIndexStats().vectors == 0)
        #expect(!ContextIndexingEngine(store: store, hooks: Self.hooks(available: false), producer: nil).coverage().encoderAvailable)
    }

    @Test func editsAndDeletionsDuringABatchNeverPublishObsoleteVectors() async throws {
        let (store, ids) = try Self.library(meetings: 2, lines: 20)
        // Newest meeting first: the first batch holds ids[1]'s chunks. Edit and delete while the worker "computes".
        let tr = try #require(try store.meeting(ids[1])?.currentTranscriptRevisionID)
        let e = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: Self.fakeEmbed(before: { _ in
            try store.appendEdit(UserEdit(meetingID: ids[1], baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                          operation: .correctText(WordRange(revisionID: tr, first: WordID("1-0-0"), last: WordID("1-0-0")), replacement: "EDITED")))
            try store.tombstone(ids[0])
        })), producer: nil)
        _ = await e.step()
        let current = Set(try store.contextChunks(ids[1]).map(\.contentHash))
        let stats = try store.contextIndexStats()
        // Every stored vector belongs to a current chunk of a live meeting; the edited chunk is pending again.
        #expect(try store.vectorSearch(FakeEncoder.vector("plans"), producer: FakeEncoder.producer, filter: ContextFilter(), k: 1000).allSatisfy { $0.meetingID == ids[1] && current.contains($0.contentHash) })
        #expect(try store.pendingContextChunks(producer: FakeEncoder.producer.id, limit: 100).contains { $0.text.contains("EDITED") })
        #expect(stats.vectors < current.count + 1)
        #expect(try store.contextChunks(ids[0]).isEmpty)
    }

    @Test func replacedModelRebuildsWithoutMixingGenerations() async throws {
        let (store, _) = try Self.library(meetings: 1, lines: 30)
        let e1 = ContextIndexingEngine(store: store, hooks: Self.hooks(), producer: nil)
        _ = await drain(e1)
        var p2 = FakeEncoder.producer; p2.revision = "2"
        let changed = Box<EncoderProducer?>(nil)
        // The user installed a new encoder revision: the remembered producer no longer matches it.
        let e2 = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: Self.fakeEmbed(p2), revision: "2"), producer: e1.producer)
        #expect(!e2.coverage().encoderAvailable || !e2.coverage().complete, "coverage doesn't count the old generation")
        e2.onProducerChange = { p in changed.with { $0 = p } }
        _ = await drain(e2)
        #expect(changed.value?.id == p2.id)
        #expect(try store.vectorSearch(FakeEncoder.vector("plans"), producer: FakeEncoder.producer, filter: ContextFilter(), k: 10).isEmpty, "old generation dropped")
        #expect(e2.coverage().complete && e2.activeProducer?.id == p2.id)
    }

    @Test func rejectedTextsAreCountedTransportErrorsAreNot() async throws {
        let (store, _) = try Self.library(meetings: 1, lines: 10)
        let e0 = ContextIndexingEngine(store: store, hooks: Self.hooks(), producer: nil)
        _ = await e0.step()   // learn the producer
        // A new meeting's text the encoder rejects three times is skipped (still uncovered), not retried forever.
        let (s2, _) = (store, try Self.library(meetings: 0))
        _ = s2
        let rejecting = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: { _, _ in throw ContextIndexingEngine.IndexingError.rejected("bad") }), producer: e0.producer)
        let tr = try #require(try store.meetings().first?.currentTranscriptRevisionID)
        let m = try #require(try store.meetings().first?.id)
        try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: tr, sequence: 1, createdAt: Date(),
                                      operation: .correctText(WordRange(revisionID: tr, first: WordID("0-0-0"), last: WordID("0-0-0")), replacement: "NEW")))
        for _ in 0..<3 { if case .failed = await rejecting.step() {} else { Issue.record("expected failed") } }
        #expect(await rejecting.step() == .idle)
        #expect(!rejecting.coverage().complete)
        // Transport errors (worker crash) aren't the text's fault.
        struct Crash: Error {}
        try store.clearContextFailures(producer: e0.producer!.id)
        let crashing = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: { _, _ in throw Crash() }), producer: e0.producer)
        for _ in 0..<5 { _ = await crashing.step() }
        #expect(try store.pendingContextChunks(producer: e0.producer!.id, limit: 10).count == 1)
    }

    @Test func cancelCurrentStopsTheBatchInTheWorker() async throws {
        let (store, _) = try Self.library(meetings: 1)
        let cancelled = Box<String?>(nil)
        let started = Box(false)
        let e = ContextIndexingEngine(store: store, hooks: Self.hooks(embed: { id, _ in
            started.with { $0 = true }
            for _ in 0..<200 { if cancelled.value == id { throw CancellationError() }; try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }, cancel: { id in cancelled.with { $0 = id } }), producer: nil)
        let task = Task { await e.step() }
        while !started.value { try await Task.sleep(for: .milliseconds(5)) }
        let t0 = ContinuousClock.now
        e.cancelCurrent()
        #expect(await task.value == .cancelled)
        #expect(ContinuousClock.now - t0 < .seconds(1))
        #expect(try store.contextIndexStats().vectors == 0)
    }
}
