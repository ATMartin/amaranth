import CryptoKit
import Foundation
import Testing
@testable import Capture
import Domain
import Storage

/// In-process crash-recovery scenarios. The real force-kill test lives in ForceKillTests.
@Suite("Crash recovery", .serialized)
struct RecoveryTests {
    static let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)

    func record(seconds: Double, root: URL, store: MeetingStore?) async throws -> CaptureResult {
        let plan = SyntheticSource.Plan(format: Self.fmt, callbackFrames: 320, speed: 8) { i, _ in Float(i % 100_000) / 100_000 }
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly),
                                     store: store) { kind in SyntheticSource(kind: kind, plan: plan) }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .seconds(seconds))
        return s.stop()
    }

    func tempRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "amr-rec-\(UUID())") }

    @Test func sessionIndexesWhileRecording() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let r = try await record(seconds: 1.2, root: root, store: store)
        #expect(try store.segments(r.meetingID).count == r.segments.count)
        #expect(try store.epochs(r.meetingID).count == r.epochs.count)
        let m = try #require(try store.meeting(r.meetingID))
        #expect(m.captureState == .captured)
        #expect(m.duration.seconds > 1.0, "session duration is wall-clock session time (synthetic audio runs 8× faster)")
    }

    @Test func rebuildsLostIndexFromFilesAndJournal() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await record(seconds: 1.2, root: root, store: try MeetingStore(root: root))
        // Simulate losing the database entirely (e.g. crash before the indexer flushed, or a damaged DB file).
        for name in ["amaranth.sqlite", "amaranth.sqlite-wal", "amaranth.sqlite-shm"] { try? FileManager.default.removeItem(at: root.appending(path: name)) }
        let fresh = try MeetingStore(root: root)
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: fresh)
        #expect(res.report.reindexed.count == r.segments.count)
        #expect(res.report.quarantined.isEmpty)
        let rows = try fresh.segments(r.meetingID)
        #expect(Set(rows.map(\.id)) == Set(r.segments.map(\.id)))
        #expect(Set(rows.map(\.sha256)) == Set(r.segments.map(\.sha256)), "hashes recomputed from file bytes match the originals")
        #expect(res.replayedEpochs == r.epochs.count, "epochs come back from the journal")
    }

    @Test func indexesSelfDescribingFilesEvenWithoutJournal() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await record(seconds: 0.8, root: root, store: nil)
        try FileManager.default.removeItem(at: r.directory.appending(path: "journal.jsonl"))
        let store = try MeetingStore(root: root)
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: store)
        #expect(res.segmentsIndexedTotal == r.segments.count)
    }

    @Test func truncatedCommittedFileIsQuarantinedAndReported() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await record(seconds: 0.8, root: root, store: nil)
        let victim = try #require(r.segments.dropFirst().first)
        let url = r.directory.appending(path: victim.relativePath)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 1000).write(to: url)
        let store = try MeetingStore(root: root)
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: store)
        #expect(res.report.quarantined.count == 1)
        #expect(res.report.damagedIntervals == [victim.interval])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(res.segmentsIndexedTotal == r.segments.count - 1, "all other segments preserved")
        #expect(try store.events(r.meetingID).contains { $0.isMissingAudio && $0.interval == victim.interval }, "damage is explicit")
    }

    @Test func interruptedStagingWriteIsSalvagedToWholeFrames() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await record(seconds: 0.8, root: root, store: nil)
        // Re-create the crash: take a committed segment, remove it, and leave a torn copy in staging.
        let victim = try #require(r.segments.last)
        let url = r.directory.appending(path: victim.relativePath)
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        let torn = data.prefix(data.count / 2 + 3) // mid-frame tear
        try torn.write(to: r.directory.appending(path: "audio/.staging/microphone-\(victim.sequence).caf.partial"))
        let store = try MeetingStore(root: root)
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: store)
        let s = try #require(res.salvaged.first)
        #expect(s.id == victim.id && s.frameCount > 0 && s.frameCount < victim.frameCount)
        #expect(s.interval.start == victim.interval.start && s.interval.end < victim.interval.end)
        let back = try CAFFile.decode(Data(contentsOf: url))
        #expect(Int64(back.frameCount) == s.frameCount, "salvaged file is a complete, valid segment")
        let original = try CAFFile.decode(data)
        #expect(Array(back.samples) == Array(original.samples.prefix(back.samples.count)), "salvaged samples are the original samples")
        #expect(try store.events(r.meetingID).contains { $0.reasonCode == "recovery.truncatedSegment" && $0.interval.end == victim.interval.end })
    }

    @Test func tornJournalLineIsTolerated() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await record(seconds: 0.8, root: root, store: nil)
        let j = try FileHandle(forWritingTo: r.directory.appending(path: "journal.jsonl"))
        try j.seekToEnd(); try j.write(contentsOf: Data(#"{"contractVersion":1,"payload":{"segm"#.utf8)); try j.close()
        let res = try SegmentRecovery.recover(meetingID: r.meetingID, directory: r.directory, store: try MeetingStore(root: root))
        #expect(res.segmentsIndexedTotal == r.segments.count)
    }
}

@Suite("Session lifecycle hardening", .serialized)
struct SessionHardeningTests {
    static let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
    func tempRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "amr-life-\(UUID())") }

    /// T42: a recording starts in the chosen folder; a folder deleted meanwhile leaves it unfiled instead of failing.
    @Test func recordingStartsInTheChosenFolder() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let acme = try store.createFolder(name: "Acme")
        let plan = SyntheticSource.Plan.sine(440, format: Self.fmt, speed: 1)
        let filed = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly),
                                         store: store, folderID: acme.id) { SyntheticSource(kind: $0, plan: plan) }
        #expect(try store.meeting(filed.meetingID)?.folderID == acme.id)
        let orphan = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly),
                                          store: store, folderID: FolderID("deleted")) { SyntheticSource(kind: $0, plan: plan) }
        #expect(try store.meeting(orphan.meetingID)?.folderID == nil)
    }

    @Test func lowDiskWarnsThenStopsAndSavesWithoutDeletingAudio() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let free = FreeSpace(5 << 30)
        let opts = RecordingOptions(selection: .microphoneOnly, diskReserveBytes: 1 << 30, diskWarnBytes: 2 << 30,
                                    availableBytes: { _ in free.value })
        let plan = SyntheticSource.Plan.sine(440, format: Self.fmt, speed: 1)
        let store = try MeetingStore(root: root)
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: opts, store: store) { SyntheticSource(kind: $0, plan: plan) }
        let stopped = Flag()
        s.onAutoStop = { _ in stopped.set() }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(2500))
        free.value = (3 << 29) // 1.5 GB: below warn threshold, above reserve
        try await Task.sleep(for: .milliseconds(2500))
        #expect(s.snapshot().events.contains { $0.kind == .diskLow })
        #expect(s.state == .recording)
        free.value = (1 << 29) // 0.5 GB: below reserve → stop and save
        for _ in 0..<60 where !stopped.isSet { try await Task.sleep(for: .milliseconds(100)) }
        #expect(stopped.isSet)
        let r = s.stop() // a second stop returns the same sealed result
        #expect(r.events.contains { $0.kind == .stoppedForDiskSpace })
        #expect(r.finalState == .captured)
        #expect(!r.segments.isEmpty)
        for seg in r.segments { #expect(FileManager.default.fileExists(atPath: r.directory.appending(path: seg.relativePath).path)) }
        #expect(try store.meeting(r.meetingID)?.captureState == .captured, "partial meeting is saved and playable")
    }

    @Test func sleepInterruptsAndExplicitResumeStartsWakeEpochs() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = SyntheticSource.Plan.sine(440, format: Self.fmt, speed: 1)
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly)) {
            SyntheticSource(kind: $0, plan: plan)
        }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(600))
        s.interrupt(reason: "system.sleep")
        #expect(s.state == .interrupted)
        try await Task.sleep(for: .milliseconds(700))
        s.resume()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(600))
        let r = s.stop()
        let sleep = try #require(r.events.first { $0.kind == .sleep && $0.interval.duration.seconds > 0.5 })
        #expect(r.events.contains { $0.kind == .wake })
        #expect(r.epochs.map(\.reason) == [.sessionStart, .wake])
        #expect(r.epochs[1].sessionStart + .seconds(0.05) >= sleep.interval.end)
        let missing = r.events.filter { $0.isMissingAudio }
        #expect(missing.isEmpty, "sleep is recorded as sleep, not as a gap: \(missing)")
        #expect(r.finalState == .captured)
    }

    @Test func stoppingWhileInterruptedSealsTheSession() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = SyntheticSource.Plan.sine(440, format: Self.fmt, speed: 1)
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly)) {
            SyntheticSource(kind: $0, plan: plan)
        }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(500))
        s.interrupt(reason: "system.sleep")
        let r = s.stop()
        #expect(r.finalState == .captured)
        #expect(r.events.contains { $0.kind == .sleep && $0.interval.duration.seconds >= 0 })
    }

    @Test func failedCommitsBecomeExplicitGapsNeverSilentLoss() async throws {
        let root = tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let plan = SyntheticSource.Plan.sine(440, format: Self.fmt, speed: 4)
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .microphoneOnly)) {
            SyntheticSource(kind: $0, plan: plan)
        }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(800))
        // The minute directory exists already; make the source's audio directory unwritable so new minute shards and
        // staging fail. Simplest robust trigger: remove write permission on the staging directory.
        let staging = s.directory.appending(path: "audio/.staging")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
        try await Task.sleep(for: .milliseconds(1500))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try await Task.sleep(for: .milliseconds(600))
        let r = s.stop()
        let failed = r.events.filter { $0.reasonCode == "writer.commitFailed" }
        #expect(!failed.isEmpty)
        #expect(r.finalState == .capturedWithGaps)
        // Every second of the session is either a committed segment or an explicit missing-audio interval.
        let covered = r.segments.map(\.interval) + r.events.filter(\.isMissingAudio).map(\.interval)
        let total = covered.reduce(0.0) { $0 + $1.duration.seconds }
        let span = (r.segments.map(\.interval.end).max() ?? .zero) - (r.segments.map(\.interval.start).min() ?? .zero)
        #expect(total + 0.05 >= span.seconds)
    }
}

final class FreeSpace: @unchecked Sendable {
    private let lock = NSLock(); private var v: Int64
    init(_ v: Int64) { self.v = v }
    var value: Int64 { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.withLock { v = true } }
    var isSet: Bool { lock.withLock { v } }
}

@Suite("Independent source failure", .serialized)
struct IndependentSourceTests {
    @Test func healthySourceContinuesWhileOtherDisconnects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-indep-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
        var made: [SourceKind: SyntheticSource] = [:]
        let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: RecordingOptions(selection: .both)) { kind in
            let src = SyntheticSource(kind: kind, plan: .sine(kind == .microphone ? 440 : 880, format: fmt))
            made[kind] = src
            return src
        }
        try s.start()
        _ = await s.waitUntilRecording()
        try await Task.sleep(for: .milliseconds(1500))
        made[.systemOutput]!.stalled = true          // system device disappears
        try await Task.sleep(for: .milliseconds(2500))
        #expect(s.health().first { $0.source == .systemOutput }?.status == .degraded, "the failed source is visible")
        #expect(s.health().first { $0.source == .microphone }?.status != .degraded, "the healthy source is unaffected")
        made[.systemOutput]!.stalled = false         // device comes back
        try await Task.sleep(for: .milliseconds(1500))
        let r = s.stop()
        // Microphone: one contiguous epoch, no gaps, covering the whole session.
        let mic = r.segments.filter { $0.source == .microphone }.sorted { $0.sequence < $1.sequence }
        for (a, b) in zip(mic, mic.dropFirst()) { #expect(a.interval.end == b.interval.start) }
        #expect(!r.events.contains { $0.source == .microphone && $0.isMissingAudio })
        #expect((mic.last?.interval.end.seconds ?? 0) > 5)
        // System: the missing interval is explicit, and capture resumed afterwards.
        let gaps = r.events.filter { $0.source == .systemOutput && $0.isMissingAudio }
        #expect(!gaps.isEmpty)
        #expect(MeetingStatus.missingSeconds(gaps) > 2 && MeetingStatus.missingSeconds(gaps) < 4)
        #expect(r.events.contains { $0.source == .systemOutput && $0.kind == .sourceRecovered })
        let lastSys = r.segments.filter { $0.source == .systemOutput }.map(\.interval.end.seconds).max() ?? 0
        #expect(lastSys > 5, "system capture resumed after the device returned")
        #expect(r.finalState == .capturedWithGaps)
    }
}
