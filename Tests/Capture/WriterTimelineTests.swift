import Foundation
import Testing
@testable import Capture
import Domain

/// Writer/timeline behaviour with deterministic synthetic sources running faster than realtime.
@Suite("Segment writer and timeline", .serialized)
struct WriterTimelineTests {
    static let mono48 = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
    static let stereo44 = AudioFormat(sampleRate: 44_100, channelCount: 2, sampleFormat: .float32)

    /// Ramp signal: sample value encodes its own frame index so continuity/duplication is checkable exactly.
    static func rampPlan(_ f: AudioFormat, speed: Double = 8, jumps: [Int64: Int64] = [:]) -> SyntheticSource.Plan {
        SyntheticSource.Plan(format: f, callbackFrames: 512, speed: speed, sampleTimeJumps: jumps) { i, c in
            Float(i % 1_000_000) + Float(c) * 0.5
        }
    }

    func tempRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "amr-cap-\(UUID())") }

    func record(_ plans: [SourceKind: SyntheticSource.Plan], seconds: Double,
                during: ((RecordingSession, [SourceKind: SyntheticSource]) async throws -> Void)? = nil) async throws
        -> (CaptureResult, [SourceKind: SyntheticSource]) {
        var made: [SourceKind: SyntheticSource] = [:]
        let selection: SourceSelection = plans.count == 2 ? .both : (plans.keys.first == .microphone ? .microphoneOnly : .systemOnly)
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: tempRoot(), options: RecordingOptions(selection: selection)) { kind in
            let s = SyntheticSource(kind: kind, plan: plans[kind]!)
            made[kind] = s
            return s
        }
        try session.start()
        #expect(await session.waitUntilRecording(), "recording only once frames flow")
        if let during { try await during(session, made) } else { try await Task.sleep(for: .seconds(seconds)) }
        return (session.stop(), made)
    }

    func decode(_ r: CaptureResult, _ kind: SourceKind) throws -> [(AudioSegmentRecord, CAFFile.Decoded)] {
        try r.segments.filter { $0.source == kind }.map { ($0, try CAFFile.decode(Data(contentsOf: r.directory.appending(path: $0.relativePath)))) }
    }

    @Test func segmentsAreContiguousSampleExactAndJournaled() async throws {
        let (r, _) = try await record([.microphone: Self.rampPlan(Self.mono48), .systemOutput: Self.rampPlan(Self.stereo44)], seconds: 1.5)
        #expect(r.finalState == .captured)
        for kind in SourceKind.allCases {
            let segs = try decode(r, kind)
            #expect(segs.count >= 4, "≥ 8 s of audio at 8× speed")
            var expectedNext: Float = 0
            for (i, (rec, d)) in segs.enumerated() {
                #expect(rec.state == .committed && rec.sha256.count == 64)
                #expect(d.format == rec.format && Int64(d.frameCount) == rec.frameCount)
                if i > 0 { #expect(rec.interval.start == segs[i - 1].0.interval.end, "no gap or overlap between segments") }
                #expect(rec.firstFrameInEpoch == (i == 0 ? 0 : segs[i - 1].0.firstFrameInEpoch + segs[i - 1].0.frameCount))
                // First channel carries the frame index: verify no dropped or duplicated frames anywhere.
                #expect(d.samples[0] == expectedNext)
                let lastFrame = d.samples[(d.frameCount - 1) * d.format.channelCount]
                #expect(lastFrame == expectedNext + Float(d.frameCount - 1))
                expectedNext = lastFrame + 1
            }
            // Full segments are exactly 2 s (except the final partial one).
            for (rec, _) in segs.dropLast() { #expect(rec.frameCount == Int64(rec.format.sampleRate * 2)) }
        }
        let journal = try String(contentsOf: r.directory.appending(path: "journal.jsonl"), encoding: .utf8)
        let entries = journal.split(separator: "\n").compactMap { try? ContractCoding.decode(JournalEntry.self, from: Data($0.utf8)) }
        let journaledSegments = entries.compactMap { if case .segment(let s) = $0 { s } else { nil } }
        let journaledEpochs = entries.compactMap { if case .epoch(let e) = $0 { e } else { nil } }
        #expect(Set(journaledSegments.map(\.id)) == Set(r.segments.map(\.id)))
        #expect(Set(journaledEpochs.map(\.id)) == Set(r.epochs.map(\.id)))
        #expect(r.events.isEmpty)
        #expect(r.ringStats.values.allSatisfy { $0.overrunFrames == 0 })
        // Staging directory is left empty: nothing uncommitted remains.
        let staging = try FileManager.default.contentsOfDirectory(atPath: r.directory.appending(path: "audio/.staging").path)
        #expect(staging.isEmpty)
    }

    @Test func sourcesKeepSeparateFormatsAndClocks() async throws {
        let (r, _) = try await record([.microphone: Self.rampPlan(Self.mono48), .systemOutput: Self.rampPlan(Self.stereo44)], seconds: 0.6)
        let mic = r.epochs.first { $0.source == .microphone }!, sys = r.epochs.first { $0.source == .systemOutput }!
        #expect(mic.format == Self.mono48 && sys.format == Self.stereo44)
        #expect(mic.id != sys.id)
    }

    @Test func deviceSampleTimeJumpBecomesExplicitGap() async throws {
        // Skip 24 000 frames (0.5 s) at frame 96 256 (≈ 2 s in).
        let plan = Self.rampPlan(Self.mono48, jumps: [96_256: 24_000])
        let (r, _) = try await record([.microphone: plan], seconds: 1.0)
        let gap = try #require(r.events.first { $0.kind == .gap })
        #expect(gap.source == .microphone && gap.lostFrames == 24_000 && gap.reasonCode == "device.sampleTimeJump")
        #expect(gap.interval.duration == SessionDuration(nanoseconds: 500_000_000))
        #expect(r.finalState == .capturedWithGaps)
        // Timeline is not collapsed: the segment after the gap starts at the gap's end, frame index advanced.
        let after = try #require(r.segments.first { $0.interval.start == gap.interval.end })
        #expect(after.firstFrameInEpoch == 96_256 + 24_000)
        #expect(!r.segments.contains { $0.interval.overlaps(gap.interval) })
    }

    @Test func pauseCreatesEventAndNewEpochWithoutSavingPausedAudio() async throws {
        let (r, _) = try await record([.microphone: Self.rampPlan(Self.mono48, speed: 1)], seconds: 0) { session, _ in
            try await Task.sleep(for: .milliseconds(700))
            session.pause()
            try await Task.sleep(for: .milliseconds(600))
            session.resume()
            try await Task.sleep(for: .milliseconds(700))
        }
        let pause = try #require(r.events.first { $0.kind == .pause })
        #expect(pause.source == nil)
        #expect(pause.interval.duration.seconds > 0.5 && pause.interval.duration.seconds < 0.8)
        let epochs = r.epochs.filter { $0.source == .microphone }
        #expect(epochs.map(\.reason) == [.sessionStart, .resume])
        #expect(epochs[1].sessionStart + .seconds(0.05) >= pause.interval.end)
        #expect(!r.segments.contains { $0.interval.intersection(pause.interval).map { $0.duration.seconds > 0.05 } ?? false })
        #expect(r.finalState == .captured, "a pause is not missing audio")
    }

    @Test func stalledCallbacksRaiseFaultWithinTwoSeconds() async throws {
        let (r, _) = try await record([.microphone: Self.rampPlan(Self.mono48, speed: 1)], seconds: 0) { session, sources in
            try await Task.sleep(for: .milliseconds(500))
            sources[.microphone]!.stalled = true
            let stalledAt = Date()
            var detected: TimeInterval?
            while Date().timeIntervalSince(stalledAt) < 3 {
                if session.health().first?.status == .degraded { detected = Date().timeIntervalSince(stalledAt); break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(detected != nil && detected! < 2.0, "fault visible within 2 s (threshold 1 s + watchdog period)")
            sources[.microphone]!.stalled = false
            try await Task.sleep(for: .milliseconds(800))
        }
        #expect(r.events.contains { $0.kind == .sourceFault && $0.reasonCode == "callbacks.stalled.detected" })
        #expect(r.events.contains { $0.kind == .sourceRecovered })
        // The stalled device clock resumed without a sample-time jump: the writer must re-anchor, not shift audio earlier.
        let gap = try #require(r.events.first { $0.reasonCode == "clock.discontinuity" })
        #expect(gap.interval.duration.seconds > 1.0)
        #expect(r.epochs.filter { $0.source == .microphone }.map(\.reason) == [.sessionStart, .restartAfterFault])
        #expect(r.finalState == .capturedWithGaps)
    }

    @Test func stateIsPreparingUntilFramesArriveAndDelayedStartIsAGap() async throws {
        let session = try RecordingSession(meetingID: MeetingID(), rootDirectory: tempRoot(), options: RecordingOptions(selection: .microphoneOnly)) { kind in
            let s = SyntheticSource(kind: kind, plan: Self.rampPlan(Self.mono48, speed: 1))
            s.stalled = true // simulates a source blocked on a permission prompt
            return s
        }
        try session.start()
        try await Task.sleep(for: .milliseconds(3500))
        #expect(session.state == .preparing)
        #expect(session.health().first?.status == .degraded, "a source with no audio is visibly faulted")
        // Unblock (user clicked Allow).
        (session.sourcesForTesting[.microphone] as? SyntheticSource)?.stalled = false
        #expect(await session.waitUntilRecording())
        try await Task.sleep(for: .milliseconds(300))
        let r = session.stop()
        let gap = try #require(r.events.first { $0.reasonCode == "source.startDelayed" })
        #expect(gap.interval.start == .zero && gap.interval.end.seconds > 3.4)
        #expect(r.events.contains { $0.reasonCode == "source.noAudio.detected" })
        #expect(r.events.contains { $0.kind == .sourceRecovered })
    }

    @Test func gradualClockDriftIsReportedNotTreatedAsDiscontinuity() async throws {
        var plan = Self.rampPlan(Self.mono48, speed: 16)
        plan.hostClockPPM = 2000 // 20× worse than a typical crystal; 16 s of audio ⇒ 32 ms total drift
        let (r, _) = try await record([.microphone: plan], seconds: 1.0)
        #expect(!r.events.contains { $0.reasonCode == "clock.discontinuity" })
        #expect(r.epochs.count == 1)
        let drift = try #require(r.writerStats[.microphone]?.maxDriftNanos)
        #expect(drift > 10_000_000 && drift < 60_000_000, "drift measured: \(drift) ns")
    }

    @Test func metersPublishBoundedRate() async throws {
        let (r, _) = try await record([.microphone: .sine(1000, amplitude: 0.5, format: Self.mono48, speed: 1)], seconds: 0) { session, _ in
            try await Task.sleep(for: .milliseconds(600))
            let m = try #require(session.meters()[.microphone])
            #expect(abs(m.peakDBFS - (-6.02)) < 0.2)
            #expect(abs(m.rmsDBFS - (-9.03)) < 0.3)
        }
        #expect(r.finalState == .captured)
    }
}
