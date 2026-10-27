public import Foundation
public import Domain
public import Storage

public struct RecordingOptions: Sendable {
    public var selection: SourceSelection
    public var microphoneUID: String?
    public var allowDefaultMicrophoneFallback: Bool
    public var writer: SegmentWriterConfiguration
    /// A source with no callbacks for this long is a fault (plan §6 "Health": visible within 2 s of detection).
    public var callbackStallThreshold: Duration
    /// Stop and save when free space falls below this (kept separate from model downloads).
    public var diskReserveBytes: Int64
    /// Warn when projected remaining recording time or free space falls below these.
    public var diskWarnSeconds: Double
    public var diskWarnBytes: Int64
    /// Free-space probe for the recording volume (injectable for tests).
    public var availableBytes: @Sendable (URL) -> Int64?

    public init(selection: SourceSelection = .both, microphoneUID: String? = nil, allowDefaultMicrophoneFallback: Bool = false,
                writer: SegmentWriterConfiguration = .init(), callbackStallThreshold: Duration = .milliseconds(1000),
                diskReserveBytes: Int64 = 1 << 30, diskWarnSeconds: Double = 15 * 60, diskWarnBytes: Int64 = 2 << 30,
                availableBytes: @escaping @Sendable (URL) -> Int64? = RecordingOptions.volumeAvailableBytes) {
        self.selection = selection
        self.microphoneUID = microphoneUID
        self.allowDefaultMicrophoneFallback = allowDefaultMicrophoneFallback
        self.writer = writer
        self.callbackStallThreshold = callbackStallThreshold
        self.diskReserveBytes = diskReserveBytes
        self.diskWarnSeconds = diskWarnSeconds
        self.diskWarnBytes = diskWarnBytes
        self.availableBytes = availableBytes
    }

    public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

public struct CaptureResult: Sendable {
    public var meetingID: MeetingID
    public var directory: URL
    public var clock: SessionClock
    public var duration: SessionDuration
    public var finalState: CaptureState
    public var epochs: [CaptureEpoch]
    public var segments: [AudioSegmentRecord]
    public var events: [CaptureEvent]
    public var writerStats: [SourceKind: WriterSourceStats]
    public var ringStats: [SourceKind: RingStats]
    public var startErrors: [SourceKind: String]
}

/// One meeting's capture: starts the selected sources, drains them into durable segments, watches health,
/// and records pauses, gaps and device changes as explicit events. Sources fail independently.
public final class RecordingSession: @unchecked Sendable {
    public let meetingID: MeetingID
    public let directory: URL
    public let clock: SessionClock
    public let options: RecordingOptions

    private let writer: SegmentWriter
    private var sources: [SourceKind: RingAudioSource] = [:]
    private let lock = NSLock()
    private var _state: CaptureState = .preparing
    private var epochs: [CaptureEpoch] = []
    private var segments: [AudioSegmentRecord] = []
    private var events: [CaptureEvent] = []
    private var startErrors: [SourceKind: String] = [:]
    private var openFaults: [SourceKind: (start: SessionTime, reason: String)] = [:]
    private var watchdog: (any DispatchSourceTimer)?
    private var eventTasks: [Task<Void, Never>] = []
    private var activity: (any NSObjectProtocol)?
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    public let liveEvents: AsyncStream<CaptureEvent>
    private let store: MeetingStore?
    private let indexer: SegmentIndexer?
    private var meeting: Meeting
    private var interruptedAt: SessionTime?
    private var diskWarned = false
    private var autoStopping = false
    private var stopInvoked = false
    private var finalResult: CaptureResult?
    private var lastDiskCheckNanos: UInt64 = 0
    /// Called (off the main thread) after the session stopped itself, e.g. to protect the disk.
    public var onAutoStop: (@Sendable (CaptureResult) -> Void)?

    /// Creates the session directory and writer. Call `start` to begin capture.
    /// With a `store`, the session writes a meeting row (state tracks capture) and indexes epochs, segments and events
    /// as they happen; `rootDirectory` should then be `store.root` so files live where the index expects them.
    public init(meetingID: MeetingID, rootDirectory: URL, options: RecordingOptions, store: MeetingStore? = nil,
                title: String = "Untitled meeting",
                sourceFactory: (SourceKind) -> RingAudioSource = RecordingSession.defaultSource) throws {
        self.meetingID = meetingID
        self.options = options
        self.store = store
        indexer = store.map { SegmentIndexer(store: $0) }
        directory = rootDirectory.appending(path: "meetings/\(meetingID.rawValue)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let origin = HostClock.nowNanos()
        clock = SessionClock(utcOrigin: Date(), timeZoneIdentifier: TimeZone.current.identifier, hostTimeOriginNanos: origin)
        writer = try SegmentWriter(meetingID: meetingID, meetingDirectory: directory, sessionOriginHostNanos: origin,
                                   configuration: options.writer)
        (liveEvents, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(512))
        meeting = Meeting(id: meetingID, title: title, createdAt: clock.utcOrigin, clock: clock, captureState: .preparing,
                          selectedSources: options.selection)
        try store?.upsertMeeting(meeting)
        for kind in options.selection.sources.sorted(by: { $0.rawValue < $1.rawValue }) {
            let s = sourceFactory(kind)
            sources[kind] = s
            writer.attach(s)
        }
        writer.onCommit = { [weak self] r in
            self?.lock.withLock { self?.segments.append(r) }
            self?.indexer?.add(r)
        }
        writer.onEpoch = { [weak self] e in
            self?.lock.withLock { self?.epochs.append(e) }
            self?.indexer?.add(e)
        }
        writer.onEvent = { [weak self] e in self?.record(e) }
        // "Recording" is shown only once audio actually flows, not while waiting for permission or devices.
        writer.onFirstFrame = { [weak self] _ in self?.transition(to: .recording) }
    }

    public static func defaultSource(_ kind: SourceKind) -> RingAudioSource {
        kind == .microphone ? HALInputSource() : SystemAudioTapSource()
    }

    public var state: CaptureState { lock.withLock { _state } }
    var sourcesForTesting: [SourceKind: RingAudioSource] { sources }
    public var now: SessionTime { SessionTime(nanoseconds: Int64(HostClock.nowNanos()) - Int64(clock.hostTimeOriginNanos)) }

    /// Starts every selected source. Succeeds if at least one source starts; a failed source is reported, not hidden.
    /// "Recording" is shown only once capture is active.
    public func start() throws {
        writer.start()
        for (kind, src) in sources {
            eventTasks.append(Task { [weak self] in
                for await e in src.events { self?.handleSourceEvent(kind, e) }
            })
            do {
                try src.start(AudioSourceConfiguration(meetingID: meetingID, source: kind, deviceUID: kind == .microphone ? options.microphoneUID : nil,
                                                       allowDefaultDeviceFallback: options.allowDefaultMicrophoneFallback))
            } catch {
                lock.withLock { startErrors[kind] = "\(error)" }
                record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: now, now),
                                    kind: error as? AudioSourceError == .permissionDenied(kind) ? .permissionDenied : .sourceFault,
                                    reasonCode: "start.failed", recoverable: false))
            }
        }
        guard lock.withLock({ startErrors.count < sources.count }) else {
            writer.stop()
            transition(to: .interrupted)
            throw AudioSourceError.deviceUnavailable("no capture source could start")
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Recording a meeting")
        startWatchdog()
        // Stay `preparing` until the writer receives the first frame (see onFirstFrame).
    }

    /// Waits until capture is active (first frames received) or the timeout passes.
    @discardableResult
    public func waitUntilRecording(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while state == .preparing && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return state == .recording
    }

    public func pause() {
        guard state == .recording else { return }
        writer.pause(at: now)
        transition(to: .paused)
    }

    public func resume() {
        switch state {
        case .paused:
            writer.resume(at: now)
            transition(to: .recording)
        case .interrupted:
            // Explicit resume after sleep/interruption: record the interruption, restart sources into new `wake` epochs.
            let t = now
            if let from = lock.withLock({ interruptedAt }) {
                record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: from, max(from, t)), kind: .sleep,
                                    reasonCode: "session.interrupted", recoverable: true))
            }
            record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: t, t), kind: .wake,
                                reasonCode: "user.resume", recoverable: true))
            lock.withLock { interruptedAt = nil }
            writer.resume(at: t, recordPause: false)
            for (kind, src) in sources where lock.withLock({ startErrors[kind] == nil }) {
                try? src.start(AudioSourceConfiguration(meetingID: meetingID, source: kind, deviceUID: kind == .microphone ? options.microphoneUID : nil,
                                                        allowDefaultDeviceFallback: options.allowDefaultMicrophoneFallback))
            }
            transition(to: .recording)
        default:
            return
        }
    }

    /// Sleep or another interruption: seals what was captured, stops the sources and waits for an explicit `resume()`.
    /// Sessions are never silently concatenated across sleep.
    public func interrupt(reason: String) {
        guard state == .recording || state == .paused else { return }
        let t = now
        if state == .paused { writer.resume(at: t) }
        writer.pause(at: t, nextEpochReason: .wake)
        for s in sources.values { s.stop() }
        lock.withLock { interruptedAt = t }
        record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: t, t), kind: .sleep,
                            reasonCode: reason, recoverable: true))
        transition(to: .interrupted)
    }

    /// Stops sources, commits everything buffered, and seals the session.
    public func stop() -> CaptureResult {
        if state == .paused { writer.resume(at: now) } // closes the pause event interval
        if state == .preparing { transition(to: .recording) } // stopped before any frame arrived
        // Exactly one stop runs (user Stop and the disk guard may race); later callers wait for its result.
        let first = lock.withLock { () -> Bool in defer { stopInvoked = true }; return !stopInvoked }
        if !first {
            while lock.withLock({ finalResult == nil }) { Thread.sleep(forTimeInterval: 0.01) }
            return lock.withLock { finalResult! }
        }
        transition(to: .stopping)
        watchdog?.cancel()
        let end = now
        for s in sources.values { s.stop() }
        writer.stop()
        eventTasks.forEach { $0.cancel() }
        closeOpenFaults(at: end)
        if let from = lock.withLock({ interruptedAt }) {
            record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: from, max(from, end)), kind: .sleep,
                                reasonCode: "session.interrupted", recoverable: true))
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        let hasGaps = lock.withLock { events.contains(where: \.isMissingAudio) }
        transition(to: hasGaps ? .capturedWithGaps : .captured)
        eventContinuation.finish()
        let r = result(duration: end - .zero)
        lock.withLock { meeting.duration = r.duration }
        persistMeeting()
        indexer?.stop()
        lock.withLock { finalResult = r }
        return r
    }

    public func meters() -> [SourceKind: SourceMeter] {
        var out: [SourceKind: SourceMeter] = [:]
        for k in sources.keys { out[k] = writer.meter(k) }
        return out
    }

    public func health() -> [SourceHealth] {
        sources.keys.sorted { $0.rawValue < $1.rawValue }.map { k in
            var h = sources[k]!.health()
            h.lastCommittedSessionTime = writer.lastCommittedTime(k)
            if let m = writer.meter(k) {
                h.peakLevelDBFS = m.peakDBFS
                h.rmsLevelDBFS = m.rmsDBFS
                if h.status == .healthy {
                    if m.peakDBFS > -0.1 { h.status = .clipping } else if m.rmsDBFS < -70 { h.status = .silent }
                }
            }
            // An open fault outranks level-derived states (silent/clipping).
            if lock.withLock({ openFaults[k] != nil }), [.healthy, .silent, .clipping].contains(h.status) { h.status = .degraded }
            return h
        }
    }

    public func snapshot() -> CaptureResult { result(duration: now - .zero) }

    /// Session time of the newest committed (durable) audio per source, for "saved up to" in the recorder.
    public func lastCommitted() -> [SourceKind: SessionTime] {
        var out: [SourceKind: SessionTime] = [:]
        for k in sources.keys { if let t = writer.lastCommittedTime(k) { out[k] = t } }
        return out
    }

    /// Projected recording time left on disk (nil until a format is known), and whether the low-disk warning fired.
    public func diskStatus() -> (secondsLeft: Double?, warned: Bool) {
        let warned = lock.withLock { diskWarned }
        guard let available = options.availableBytes(directory) else { return (nil, warned) }
        let bps = sources.values.compactMap { $0.format?.bytesPerSecond }.reduce(0, +)
        guard bps > 0 else { return (nil, warned) }
        return (Double(max(0, available - options.diskReserveBytes)) / Double(bps), warned)
    }

    // MARK: Internals

    private func result(duration: SessionDuration) -> CaptureResult {
        lock.withLock {
            CaptureResult(meetingID: meetingID, directory: directory, clock: clock, duration: duration, finalState: _state,
                          epochs: epochs, segments: segments.sorted { ($0.source.rawValue, $0.sequence) < ($1.source.rawValue, $1.sequence) },
                          events: events, writerStats: writer.statistics(),
                          ringStats: sources.compactMapValues { $0.ring?.stats() }, startErrors: startErrors)
        }
    }

    private func transition(to next: CaptureState) {
        let changed = lock.withLock { () -> Bool in
            guard _state != next, _state.canTransition(to: next) else { return false }
            _state = next
            meeting.captureState = next
            return true
        }
        if changed { persistMeeting() }
    }

    private func persistMeeting() {
        guard let store else { return }
        let m = lock.withLock { meeting }
        try? store.upsertMeeting(m, keepingStoredTitle: true)   // a rename while recording wins over our copy
    }

    private func record(_ e: CaptureEvent) {
        lock.withLock { events.append(e) }
        try? writer.appendJournal(.event(e))
        indexer?.add(e)
        eventContinuation.yield(e)
    }

    private func handleSourceEvent(_ kind: SourceKind, _ e: AudioSourceEvent) {
        let t = now
        switch e {
        case .deviceLost(let reason):
            lock.withLock { if openFaults[kind] == nil { openFaults[kind] = (t, reason) } }
            record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: t, t), kind: .deviceChange,
                                reasonCode: reason, recoverable: true))
        case .deviceRecovered:
            closeFault(kind, at: t, recovered: true)
        case .formatChanged(let f):
            record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: t, t), kind: .formatChange,
                                reasonCode: "format.\(f.sampleRate)Hz.\(f.channelCount)ch", recoverable: true))
        case .permissionDenied:
            record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: t, t), kind: .permissionDenied,
                                reasonCode: "tcc.denied", recoverable: false))
        case .overrun, .started, .stopped:
            break // overruns are accounted by the writer from the ring's dropped-frame counters
        }
    }

    private func closeFault(_ kind: SourceKind, at t: SessionTime, recovered: Bool) {
        guard let f = lock.withLock({ openFaults.removeValue(forKey: kind) }) else { return }
        record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: f.start, max(f.start, t)),
                            kind: .sourceFault, reasonCode: f.reason, recoverable: true))
        if recovered {
            record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: t, t), kind: .sourceRecovered,
                                reasonCode: "source.recovered", recoverable: true))
        }
    }

    private func closeOpenFaults(at t: SessionTime) {
        for k in lock.withLock({ Array(openFaults.keys) }) { closeFault(k, at: t, recovered: false) }
    }

    /// Detects stalled callbacks (missing callbacks are a failure signal; zero amplitude is not).
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "amaranth.capture.watchdog"))
        let thresholdNs = UInt64(options.callbackStallThreshold.components.seconds) * 1_000_000_000
            + UInt64(options.callbackStallThreshold.components.attoseconds / 1_000_000_000)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, [.preparing, .recording, .paused].contains(self.state) else { return }
            let nowNs = HostClock.nowNanos()
            self.checkDisk(nowNs: nowNs)
            self.checkCommits(nowNs: nowNs)
            for (kind, src) in self.sources where self.lock.withLock({ self.startErrors[kind] == nil }) {
                let open = self.lock.withLock { self.openFaults[kind] != nil }
                guard let last = src.health().lastCallbackHostNanos, last > 0 else {
                    // Never delivered audio (permission prompt pending/denied, device not running): make it visible.
                    if !open, nowNs.subtractingSaturated(self.clock.hostTimeOriginNanos) > 3_000_000_000 {
                        self.lock.withLock { self.openFaults[kind] = (.zero, "source.noAudio") }
                        self.record(CaptureEvent(meetingID: self.meetingID, source: kind, interval: SessionInterval(unchecked: .zero, self.now),
                                                 kind: .sourceFault, reasonCode: "source.noAudio.detected", recoverable: true))
                    }
                    continue
                }
                let stalled = nowNs > last && nowNs - last > thresholdNs
                if stalled && !open {
                    let start = SessionTime(nanoseconds: Int64(last) - Int64(self.clock.hostTimeOriginNanos))
                    self.lock.withLock { self.openFaults[kind] = (start, "callbacks.stalled") }
                    self.record(CaptureEvent(meetingID: self.meetingID, source: kind, interval: SessionInterval(unchecked: start, self.now),
                                             kind: .sourceFault, reasonCode: "callbacks.stalled.detected", recoverable: true))
                } else if !stalled && open, self.lock.withLock({ ["callbacks.stalled", "source.noAudio"].contains(self.openFaults[kind]?.reason) }) {
                    self.closeFault(kind, at: self.now, recovered: true)
                }
            }
        }
        t.resume()
        watchdog = t
    }

    /// Projected recording headroom from the active stream formats; warns, then stops and saves before the disk fills.
    /// Existing audio is never deleted to make room.
    func checkDisk(nowNs: UInt64) {
        guard lastDiskCheckNanos == 0 || nowNs.subtractingSaturated(lastDiskCheckNanos) >= 2_000_000_000 else { return }
        lastDiskCheckNanos = nowNs
        guard let available = options.availableBytes(directory) else { return }
        let bytesPerSecond = sources.values.compactMap { $0.format?.bytesPerSecond }.reduce(0, +)
        let headroom = available - options.diskReserveBytes
        let seconds = bytesPerSecond > 0 ? Double(headroom) / Double(bytesPerSecond) : .infinity
        if headroom <= 0 {
            let first = lock.withLock { () -> Bool in defer { autoStopping = true }; return !autoStopping }
            guard first else { return }
            record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: now, now), kind: .stoppedForDiskSpace,
                                reasonCode: "disk.reserveReached.\(available)", recoverable: false))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let r = self.stop()
                self.onAutoStop?(r)
            }
        } else if (seconds < options.diskWarnSeconds || available < options.diskWarnBytes), !lock.withLock({ diskWarned }) {
            lock.withLock { diskWarned = true }
            record(CaptureEvent(meetingID: meetingID, source: nil, interval: SessionInterval(unchecked: now, now), kind: .diskLow,
                                reasonCode: String(format: "disk.low.%.0fs", seconds), recoverable: true))
        }
    }

    /// Callbacks flowing but no segment committed for a while means the disk path is stuck: a failure signal.
    func checkCommits(nowNs: UInt64) {
        let stats = writer.statistics()
        let limit = UInt64((options.writer.segmentSeconds * 3 + 2) * 1e9)
        for (kind, src) in sources where state == .recording {
            // Saturating differences: a callback can land between reading the clock and reading its timestamp.
            guard let lastCallback = src.health().lastCallbackHostNanos, lastCallback > 0,
                  nowNs.subtractingSaturated(lastCallback) < 1_000_000_000,
                  let ref = stats[kind]?.lastCommitHostNanos ?? stats[kind]?.firstFrameHostNanos else { continue }
            let stalled = nowNs.subtractingSaturated(ref) > limit
            let open = lock.withLock { openFaults[kind]?.reason == "commits.stalled" }
            if stalled && !open && lock.withLock({ openFaults[kind] == nil }) {
                let start = writer.lastCommittedTime(kind) ?? .zero
                lock.withLock { openFaults[kind] = (start, "commits.stalled") }
                record(CaptureEvent(meetingID: meetingID, source: kind, interval: SessionInterval(unchecked: start, max(start, now)),
                                    kind: .sourceFault, reasonCode: "commits.stalled.detected", recoverable: true))
            } else if !stalled && open {
                closeFault(kind, at: now, recovered: true)
            }
        }
    }
}

extension UInt64 {
    /// `self - other`, clamped at zero instead of trapping on underflow.
    func subtractingSaturated(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
