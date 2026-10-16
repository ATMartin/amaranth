import CryptoKit
public import Foundation
import CaptureRT
public import Domain

public enum DurabilityPolicy: String, Sendable, Codable {
    /// fsync(2) each segment before rename. Default; durable against app crash and OS crash on most hardware.
    case fsync
    /// F_FULLFSYNC: also flushes the drive cache. Measured cost decides whether it is worth it (T05).
    case fullFsync
    /// No explicit flush; for benchmarking only.
    case none
}

public struct SegmentWriterConfiguration: Sendable {
    public var segmentSeconds: Double = 2.0
    public var durability: DurabilityPolicy = .fsync
    /// Drain interval of the consumer thread.
    public var drainInterval: Duration = .milliseconds(5)
    public init(segmentSeconds: Double = 2.0, durability: DurabilityPolicy = .fsync) {
        self.segmentSeconds = segmentSeconds
        self.durability = durability
    }
}

/// Live meter values per source, published at most every ~100 ms. Never per-callback.
public struct SourceMeter: Sendable, Hashable {
    public var peakDBFS: Float
    public var rmsDBFS: Float
    public var updatedHostNanos: UInt64
}

public struct WriterSourceStats: Sendable, Hashable, Codable {
    public var firstFrameHostNanos: UInt64?
    public var firstCommitHostNanos: UInt64?
    public var framesWritten: Int64 = 0
    public var segmentsCommitted: Int = 0
    public var epochs: Int = 0
    public var gapEvents: Int = 0
    public var lostFrames: Int64 = 0
    /// Max |host-time-predicted − sample-count-predicted| session time within an epoch, ns.
    public var maxDriftNanos: Int64 = 0
    public var lastDriftNanos: Int64 = 0
    public var maxIOQueueDepth: Int = 0
    public var maxCommitLatencyNanos: UInt64 = 0
    public var lastCommitHostNanos: UInt64?
}

/// Drains source rings on a dedicated thread, maps frames onto the session timeline, and commits two-second CAF
/// segments: write to staging → flush → close → atomic rename into the committed tree → append journal → publish.
/// Disk I/O runs on a separate serial queue so a slow disk never stalls ring draining.
public final class SegmentWriter: @unchecked Sendable {
    public let meetingID: MeetingID
    public let meetingDirectory: URL
    public let sessionOriginHostNanos: UInt64
    public let configuration: SegmentWriterConfiguration

    public var onCommit: (@Sendable (AudioSegmentRecord) -> Void)?
    public var onEvent: (@Sendable (CaptureEvent) -> Void)?
    public var onEpoch: (@Sendable (CaptureEpoch) -> Void)?
    /// First frame from a source reached the writer: capture is genuinely active for it.
    public var onFirstFrame: (@Sendable (SourceKind) -> Void)?

    /// Host-vs-sample clock divergence treated as a discontinuity rather than drift.
    static let clockDiscontinuityNanos: Int64 = 250_000_000

    private let lock = NSLock()
    private var sources: [SourceKind: SourceState] = [:]
    private var thread: Thread?
    private var running = false
    private var paused = false
    private var pauseStartedAt: SessionTime?
    private let ioQueue = DispatchQueue(label: "amaranth.capture.io", qos: .userInitiated)
    private let ioGroup = DispatchGroup()
    private var ioDepth = 0
    private var journal: FileHandle?
    private let journalLock = NSLock()
    private var meters: [SourceKind: SourceMeter] = [:]
    private var stats: [SourceKind: WriterSourceStats] = [:]
    private var lastCommitted: [SourceKind: SessionTime] = [:]

    public init(meetingID: MeetingID, meetingDirectory: URL, sessionOriginHostNanos: UInt64,
                configuration: SegmentWriterConfiguration = .init()) throws {
        self.meetingID = meetingID
        self.meetingDirectory = meetingDirectory
        self.sessionOriginHostNanos = sessionOriginHostNanos
        self.configuration = configuration
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let jURL = meetingDirectory.appending(path: "journal.jsonl")
        if !fm.fileExists(atPath: jURL.path) { fm.createFile(atPath: jURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        journal = try FileHandle(forWritingTo: jURL)
        try journal?.seekToEnd()
    }

    var stagingDirectory: URL { meetingDirectory.appending(path: "audio/.staging") }

    public func attach(_ source: RingAudioSource) {
        lock.withLock { sources[source.kind] = SourceState(source: source); stats[source.kind] = WriterSourceStats() }
    }

    public func start() {
        lock.withLock { running = true }
        let t = Thread { [weak self] in self?.drainLoop() }
        t.name = "amaranth.capture.writer"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops saving both sources; frames delivered while paused are discarded intentionally (not gaps).
    public func pause(at time: SessionTime, nextEpochReason: EpochStartReason = .resume) {
        lock.withLock {
            paused = true
            pauseStartedAt = time
            for s in sources.values { s.pendingEpochReason = nextEpochReason }
        }
        drainOnce()
        flushAll()
    }

    /// `recordPause: false` for resumes after sleep/interruption, which the session records as `sleep` instead.
    public func resume(at time: SessionTime, recordPause: Bool = true) {
        let start = lock.withLock { () -> SessionTime? in
            paused = false
            defer { pauseStartedAt = nil }
            return pauseStartedAt
        }
        if let start, recordPause {
            onEvent?(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: start, max(start, time)),
                                  kind: .pause, reasonCode: "user.pause", recoverable: true))
        }
    }

    /// Drains everything still buffered, writes final partial segments, and waits for all I/O to commit.
    public func stop() {
        lock.withLock { running = false }
        while thread?.isFinished == false { Thread.sleep(forTimeInterval: 0.002) }
        drainOnce()
        flushAll()
        ioGroup.wait()
        journalLock.withLock {
            try? journal?.synchronize()
            try? journal?.close()
            journal = nil
        }
    }

    /// Appends one entry to the journal. Thread-safe. `sync` forces it to stable storage (used for rare records).
    public func appendJournal(_ entry: JournalEntry, sync: Bool = false) throws {
        var line = try ContractCoding.encode(entry)
        line.append(0x0a)
        try journalLock.withLock {
            guard let journal else { return }
            try journal.write(contentsOf: line)
            if sync { try journal.synchronize() }
        }
    }

    public func meter(_ kind: SourceKind) -> SourceMeter? { lock.withLock { meters[kind] } }
    public func statistics() -> [SourceKind: WriterSourceStats] { lock.withLock { stats } }
    public func lastCommittedTime(_ kind: SourceKind) -> SessionTime? { lock.withLock { lastCommitted[kind] } }

    // MARK: Drain

    private func drainLoop() {
        while lock.withLock({ running }) {
            drainOnce()
            Thread.sleep(forTimeInterval: Double(configuration.drainInterval.components.attoseconds) / 1e18)
        }
    }

    private func drainOnce() {
        let states = lock.withLock { Array(sources.values) }
        for s in states { drain(s) }
    }

    private func drain(_ s: SourceState) {
        // Ring replaced by a rebuild: finish the old ring, then begin a new epoch on the new one.
        if let current = s.source.ring, current !== s.ring {
            if let old = s.ring { drainRing(old, s) }
            flush(s)
            if s.ring != nil { s.pendingEpochReason = s.pendingEpochReason ?? .deviceChange }
            s.ring = current
            s.format = s.source.format
            s.scratch = [Float](repeating: 0, count: Int(AMR_MAX_CHUNK_FRAMES) * current.channels)
        }
        if let r = s.ring { drainRing(r, s) }
    }

    private func drainRing(_ ring: RealtimeRing, _ s: SourceState) {
        var chunk = amr_chunk()
        while true {
            let got = s.scratch.withUnsafeMutableBufferPointer { amr_ring_pop(ring.raw, &chunk, $0.baseAddress) }
            guard got else { break }
            process(chunk, s, channels: ring.channels)
        }
    }

    private func process(_ c: amr_chunk, _ s: SourceState, channels: Int) {
        let n = Int(c.frame_count)
        let hostNs = (c.flags & UInt32(AMR_CHUNK_HOST_TIME_VALID)) != 0 ? HostClock.ticksToNanos(c.host_time) : HostClock.nowNanos()
        let sampleValid = (c.flags & UInt32(AMR_CHUNK_SAMPLE_TIME_VALID)) != 0
        var isFirst = false
        updateStats(s.source.kind) { if $0.firstFrameHostNanos == nil { $0.firstFrameHostNanos = HostClock.nowNanos(); isFirst = true } }
        if isFirst { onFirstFrame?(s.source.kind) }
        if lock.withLock({ paused }) {
            s.expectedSampleTime = nil
            return
        }
        guard let format = s.format, format.channelCount == channels else { return }
        let rate = format.sampleRate

        if s.epoch == nil || s.pendingEpochReason != nil {
            flush(s)
            let reason = s.pendingEpochReason ?? .sessionStart
            let previousEnd = s.epoch.map { _ in s.epochTime(s.framesInEpoch) }
            beginEpoch(s, format: format, hostNs: hostNs, reason: reason)
            // Device/format rebuilds leave a real hole between epochs; record it exactly (pauses are recorded separately).
            if let previousEnd, reason != .resume, reason != .wake, let start = s.epoch?.sessionStart, start - previousEnd > .seconds(0.001) {
                emitGap(s, from: previousEnd, to: start, reason: "epoch.\(reason.rawValue)", lost: nil)
            }
            s.pendingEpochReason = nil
            s.expectedSampleTime = sampleValid ? c.sample_time : nil
        } else {
            // Discontinuity: device sample time is authoritative; dropped_frames_before classifies it as an overrun.
            var missing: Int64 = 0
            if sampleValid, let expected = s.expectedSampleTime {
                let delta = c.sample_time - expected
                if delta > 0.5 && delta < Double(rate * 30) { missing = Int64(delta.rounded()) }
                else if abs(delta) >= Double(rate * 30) || delta < -0.5 {
                    // Clock reset or wild jump: cannot place frames on the old epoch's sample timeline.
                    flush(s)
                    emitGap(s, from: s.epochTime(s.framesInEpoch), to: SessionTime(nanoseconds: Int64(hostNs) - Int64(sessionOriginHostNanos)),
                            reason: "device.sampleClockReset", lost: nil)
                    beginEpoch(s, format: format, hostNs: hostNs, reason: .restartAfterFault)
                }
            } else if c.dropped_frames_before > 0 {
                missing = Int64(c.dropped_frames_before)
            }
            if missing > 0 {
                flush(s)
                let from = s.epochTime(s.framesInEpoch)
                s.framesInEpoch += missing
                emitGap(s, from: from, to: s.epochTime(s.framesInEpoch),
                        reason: c.dropped_frames_before > 0 ? "ring.overrun" : "device.sampleTimeJump", lost: missing,
                        kind: c.dropped_frames_before > 0 ? .overrun : .gap)
            }
        }

        // Drift between host clock and sample-count timeline. Small drift is reported, not corrected (normalization
        // handles slope later). A large jump means the device clock stalled while real time moved on (or vice versa):
        // re-anchor a new epoch on host time and record the hole explicitly, so later words are not shifted.
        var predicted = s.epochTime(s.framesInEpoch).nanoseconds
        let observed = Int64(hostNs) - Int64(sessionOriginHostNanos)
        // Compare with the previous chunk's drift: gradual clock drift (tens of ppm over hours) never trips this,
        // only a sudden jump does.
        if (c.flags & UInt32(AMR_CHUNK_HOST_TIME_VALID)) != 0, let last = s.lastDrift,
           abs((observed - predicted) - last) > Self.clockDiscontinuityNanos {
            flush(s)
            let from = s.epochTime(s.framesInEpoch)
            beginEpoch(s, format: format, hostNs: hostNs, reason: .restartAfterFault)
            if let start = s.epoch?.sessionStart { emitGap(s, from: from, to: start, reason: "clock.discontinuity", lost: nil) }
            s.expectedSampleTime = sampleValid ? c.sample_time : nil
            predicted = s.epochTime(s.framesInEpoch).nanoseconds
        }
        let drift = observed - predicted
        s.lastDrift = drift
        updateStats(s.source.kind) { $0.lastDriftNanos = drift; $0.maxDriftNanos = max($0.maxDriftNanos, abs(drift)) }

        // Split at segment boundaries so every full segment is exactly `segmentSeconds` long.
        let segmentFrames = Int(Double(rate) * configuration.segmentSeconds)
        var offset = 0
        while offset < n {
            if s.segment.isEmpty {
                s.segmentStartFrame = s.framesInEpoch
                // Host-clock time of this frame: chunk host time + offset within the chunk.
                s.segmentObservedStart = SessionTime(nanoseconds: observed + Int64(offset) * 1_000_000_000 / Int64(rate))
            }
            let take = min(n - offset, segmentFrames - s.segment.count / channels)
            s.segment.append(contentsOf: s.scratch[(offset * channels)..<((offset + take) * channels)])
            s.framesInEpoch += Int64(take)
            offset += take
            if s.segment.count / channels >= segmentFrames { flush(s) }
        }
        if sampleValid { s.expectedSampleTime = c.sample_time + Double(n) }
        updateMeter(s, frames: n, channels: channels)
    }

    private func beginEpoch(_ s: SourceState, format: AudioFormat, hostNs: UInt64, reason: EpochStartReason) {
        var start = SessionTime(nanoseconds: max(0, Int64(hostNs) - Int64(sessionOriginHostNanos)))
        // Never let a new epoch overlap the previous one on the session timeline.
        if s.epoch != nil { start = max(start, s.epochTime(s.framesInEpoch)) }
        let index = (s.epoch?.index ?? -1) + 1
        let e = CaptureEpoch(meetingID: meetingID, source: s.source.kind, index: index, format: format, sessionStart: start,
                             hostTimeAtFirstFrameNanos: hostNs, deviceUID: s.source.health().deviceName, deviceName: s.source.health().deviceName,
                             reason: reason)
        s.epoch = e
        s.framesInEpoch = 0
        s.lastDrift = nil
        updateStats(s.source.kind) { $0.epochs += 1 }
        // A source that started well after Record (e.g. waiting on a permission prompt) has an unrecorded lead-in.
        if index == 0, start > .seconds(0.5) {
            emitGap(s, from: .zero, to: start, reason: "source.startDelayed", lost: nil)
        }
        try? appendJournal(.epoch(e), sync: true)
        onEpoch?(e)
    }

    private func emitGap(_ s: SourceState, from: SessionTime, to: SessionTime, reason: String, lost: Int64?, kind: CaptureEventKind = .gap) {
        guard to > from else { return }
        updateStats(s.source.kind) { $0.gapEvents += 1; $0.lostFrames += lost ?? 0 }
        onEvent?(CaptureEvent(meetingID: meetingID, source: s.source.kind, interval: SessionInterval(unchecked: from, to),
                              kind: kind, reasonCode: reason, recoverable: true, lostFrames: lost))
    }

    private func updateMeter(_ s: SourceState, frames: Int, channels: Int) {
        var peak: Float = 0, sumSq: Float = 0
        let count = frames * channels
        s.scratch.withUnsafeBufferPointer { p in
            for i in 0..<count { let v = abs(p[i]); peak = max(peak, v); sumSq += v * v }
        }
        s.meterPeak = max(s.meterPeak, peak)
        s.meterSumSq += sumSq
        s.meterCount += count
        let now = HostClock.nowNanos()
        if now - s.meterPublishedAt >= 100_000_000, s.meterCount > 0 {
            let rms = (s.meterSumSq / Float(s.meterCount)).squareRoot()
            let m = SourceMeter(peakDBFS: 20 * log10(max(s.meterPeak, 1e-9)), rmsDBFS: 20 * log10(max(rms, 1e-9)), updatedHostNanos: now)
            lock.withLock { meters[s.source.kind] = m }
            s.meterPeak = 0; s.meterSumSq = 0; s.meterCount = 0; s.meterPublishedAt = now
        }
    }

    private func updateStats(_ kind: SourceKind, _ body: (inout WriterSourceStats) -> Void) {
        lock.withLock { body(&stats[kind, default: WriterSourceStats()]) }
    }

    // MARK: Commit

    private func flushAll() {
        let states = lock.withLock { Array(sources.values) }
        for s in states { flush(s) }
    }

    private func flush(_ s: SourceState) {
        guard !s.segment.isEmpty, let epoch = s.epoch, let format = s.format else { return }
        let frames = Int64(s.segment.count / format.channelCount)
        let start = s.epochTime(s.segmentStartFrame)
        let end = s.epochTime(s.segmentStartFrame + frames)
        let seq = s.nextSequence
        s.nextSequence += 1
        let minute = start.nanoseconds / 60_000_000_000
        let rel = "audio/\(s.source.kind.rawValue)/\(String(format: "%04lld", minute))/\(String(format: "%08lld", seq)).caf"
        let samples = s.segment
        s.segment.removeAll(keepingCapacity: true)
        let record = AudioSegmentRecord(meetingID: meetingID, source: s.source.kind, epochID: epoch.id, sequence: seq, format: format,
                                        firstFrameInEpoch: s.segmentStartFrame, frameCount: frames,
                                        interval: SessionInterval(unchecked: start, end), relativePath: rel,
                                        sha256: "", state: .staged, observedStart: s.segmentObservedStart)
        let enqueuedAt = HostClock.nowNanos()
        let depth = lock.withLock { ioDepth += 1; return ioDepth }
        updateStats(s.source.kind) { $0.maxIOQueueDepth = max($0.maxIOQueueDepth, depth) }
        ioQueue.async(group: ioGroup) { [self] in
            defer { lock.withLock { ioDepth -= 1 } }
            do {
                let committed = try commit(record, samples: samples)
                let now = HostClock.nowNanos()
                updateStats(s.source.kind) {
                    $0.segmentsCommitted += 1
                    $0.framesWritten += frames
                    $0.maxCommitLatencyNanos = max($0.maxCommitLatencyNanos, now - enqueuedAt)
                    if $0.firstCommitHostNanos == nil { $0.firstCommitHostNanos = now }
                    $0.lastCommitHostNanos = now
                }
                lock.withLock { lastCommitted[s.source.kind] = committed.interval.end }
                onCommit?(committed)
            } catch {
                // A failed save is never reported as complete: surface the interval as missing audio.
                onEvent?(CaptureEvent(meetingID: meetingID, source: s.source.kind, interval: record.interval, kind: .gap,
                                      reasonCode: "writer.commitFailed", recoverable: false, lostFrames: frames))
            }
        }
    }

    /// Runs on `ioQueue`.
    private func commit(_ record: AudioSegmentRecord, samples: [Float]) throws -> AudioSegmentRecord {
        // Self-describing segment: the committed record (minus its own hash) travels inside the file.
        var embedded = record
        embedded.state = .committed
        let meta = try ContractCoding.encode(embedded)
        let data = samples.withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: record.format, metadata: meta) }
        let staged = stagingDirectory.appending(path: "\(record.source.rawValue)-\(record.sequence).caf.partial")
        let final = meetingDirectory.appending(path: record.relativePath)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SegmentStoreError.io("open \(errno)") }
        var ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
        switch configuration.durability {
        case .fsync: ok = ok && fsync(fd) == 0
        case .fullFsync: ok = ok && fcntl(fd, F_FULLFSYNC) != -1
        case .none: break
        }
        ok = (close(fd) == 0) && ok
        guard ok else { unlink(staged.path); throw SegmentStoreError.io("write/flush failed") }
        guard rename(staged.path, final.path) == 0 else { throw SegmentStoreError.io("rename \(errno)") }
        var committed = record
        committed.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        committed.state = .committed
        // Journal after the file is durable in its final location: a journal line never names an uncommitted file.
        try appendJournal(.segment(committed))
        return committed
    }
}

/// Per-source mutable state, touched only by the drain thread (plus `pause`, which sets `pendingEpochReason`).
final class SourceState: @unchecked Sendable {
    let source: RingAudioSource
    var ring: RealtimeRing?
    var format: AudioFormat?
    var scratch: [Float] = []
    var epoch: CaptureEpoch?
    var framesInEpoch: Int64 = 0
    var expectedSampleTime: Double?
    /// Host-minus-sample drift at the previous chunk; reset per epoch.
    var lastDrift: Int64?
    var pendingEpochReason: EpochStartReason?
    var segment: [Float] = []
    var segmentStartFrame: Int64 = 0
    var segmentObservedStart: SessionTime?
    var nextSequence: Int64 = 0
    var meterPeak: Float = 0
    var meterSumSq: Float = 0
    var meterCount = 0
    var meterPublishedAt: UInt64 = 0

    init(source: RingAudioSource) { self.source = source }

    func epochTime(_ frame: Int64) -> SessionTime {
        guard let e = epoch else { return .zero }
        return e.sessionStart.advanced(byFrames: frame, sampleRate: e.format.sampleRate)
    }
}
