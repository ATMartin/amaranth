import Foundation
import Observation
import Capture
import Domain
import Presentation
import Storage

/// Drives live text while recording (T14). Every `interval` seconds it checks for newly committed segments (durable
/// audio only, from `RecordingSession.snapshot()`) and sends each source's new segments to the worker, one request in
/// flight per source (T20: a short poll and per-source requests remove the wait for a tick and for the other source's
/// turn; segments stay 2 s), and merges the result. It pauses under serious or critical thermal state, under memory
/// pressure (T19) or when models are missing; capture is never affected. Final-pipeline words from incremental
/// processing replace live words (T19). Delay samples are saved per meeting (`live-latency.json`, T20).
@MainActor @Observable
final class LiveTextModel {
    enum Status: Equatable { case off, running, paused(String), unavailable(String) }
    private(set) var state = LiveTranscriptState()
    private(set) var status: Status = .off
    private var session: RecordingSession?
    private var store: MeetingStore?
    private var timer: Timer?
    /// Sources with a request at the worker (at most one each; with `perSource` false, at most one overall), for the
    /// current recording only: `generation` changes when live text detaches, so an older recording's replies never
    /// clear these.
    private var inFlight: Set<SourceKind> = []
    private var generation = 0
    private var requests = 0
    private var lastPublish = Date.distantPast
    let client: WorkerClient
    let interval: Double
    /// T20: each source gets its own request in flight instead of taking turns.
    let perSource: Bool
    /// Returns a reason to pause (pressure), or nil.
    var pauseReason: () -> String? = {
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical ? "Live text paused while the Mac is hot — recording continues" : nil
    }
    var modelsReady: () -> Bool = { true }

    init(client: WorkerClient, interval: Double = 0.25, perSource: Bool = true) {
        self.client = client
        self.interval = interval
        self.perSource = perSource
    }

    func start(session: RecordingSession, store: MeetingStore?) {
        stop(publish: false)
        self.session = session
        self.store = store
        state = LiveTranscriptState()
        requests = 0
        guard modelsReady() else { status = .unavailable("Live text needs the model pack — recording works without it"); return }
        status = .running
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops polling; publishes the provisional revision so it is visible until the final transcript replaces it.
    func stop(publish: Bool = true) {
        if publish { publishProvisional() }
        detach()
    }

    /// Stop with a final flush (T20, tracked item 23): once the recording has stopped, every source's remaining audio,
    /// including the last partial segment, is decoded with trailing padding and all of its words are kept, so the last
    /// spoken words reach the provisional transcript. Live text detaches from the recording before the first `await`
    /// and the flush works on a copy of the state, so a new recording can start at once; replies to passes still in
    /// flight are dropped (the flush re-decodes from the same stable points). Bounded by `timeout`; whatever exists
    /// then is published. Runs while paused too: it is one bounded pass after recording has ended.
    func finish(_ result: CaptureResult, timeout: Duration = .seconds(10)) async {
        guard let session, session.meetingID == result.meetingID else { stop(publish: true); return }
        timer?.invalidate(); timer = nil
        var st = state
        let store = self.store, client = self.client, requests = self.requests, interval = self.interval
        let active: Bool
        switch status { case .running, .paused: active = true; default: active = false }
        detach()
        if active {
            let deadline = ContinuousClock.now + timeout
            await withTaskGroup(of: (LiveResponse, SessionTime)?.self) { group in
                for kind in SourceKind.allCases {
                    let stable = st.stableUntil(kind)
                    let segs = result.segments.filter { $0.source == kind && $0.interval.end.seconds > stable.seconds - 2.5 }
                    guard let end = segs.map(\.interval.end).max(), end > (st.sources[kind]?.processedUntil ?? .zero) || st.sources[kind]?.tentative.isEmpty == false else { continue }
                    let request = LiveRequest(meetingID: result.meetingID, meetingDirectory: result.directory, source: kind, stableUntil: stable,
                                              segments: segs, final: true)
                    group.addTask {
                        let left = deadline - ContinuousClock.now
                        guard left > .zero, case .live(let r)? = try? await client.send(.live(request), timeout: left) else { return nil }
                        return (r, end)
                    }
                }
                for await case let (r, end)? in group { st.apply(r, sessionNow: end, measure: false) }
            }
        }
        // Show the flushed text unless a new recording has started meanwhile.
        if self.session == nil { state = st }
        if let store, let rev = st.revision(meetingID: result.meetingID, producer: Self.producer) { try? store.publishTranscript(rev, provisional: true) }
        Self.saveLatency(st, meetingID: result.meetingID, directory: result.directory, tick: interval, requests: requests)
    }

    /// Ends the current recording's polling; replies to its passes still in flight are ignored from here on.
    private func detach() {
        timer?.invalidate(); timer = nil
        session = nil
        generation += 1
        inFlight = []
        switch status { case .running, .paused: status = .off; default: break }
    }

    private func tick() {
        guard let session, session.state == .recording else { return }
        if !perSource && !inFlight.isEmpty { return }
        if let why = pauseReason() { status = .paused(why); return }
        if case .paused = status { status = .running }
        let st = state
        // Cheap check first (a short interval polls often): only take a snapshot when a source has new saved audio.
        let saved = session.lastCommitted()
        guard SourceKind.allCases.contains(where: { k in
            !inFlight.contains(k) && (saved[k]?.seconds ?? 0) - (st.sources[k]?.processedUntil.seconds ?? 0) >= 0.5
        }) else { return }
        let snapshot = session.snapshot()
        // Sources with new committed audio, the one furthest behind first.
        let candidates = SourceKind.allCases.filter { !inFlight.contains($0) }.compactMap { kind -> LiveRequest? in
            let stable = st.stableUntil(kind)
            let segs = snapshot.segments.filter { $0.source == kind && $0.interval.end.seconds > stable.seconds - 2.5 }
            guard let end = segs.map(\.interval.end).max(), end.seconds - (st.sources[kind]?.processedUntil.seconds ?? 0) >= 0.5 else { return nil }
            return LiveRequest(meetingID: session.meetingID, meetingDirectory: session.directory, source: kind, stableUntil: stable, segments: segs)
        }.sorted { (st.sources[$0.source]?.processedUntil ?? .zero) < (st.sources[$1.source]?.processedUntil ?? .zero) }
        for request in perSource ? candidates : Array(candidates.prefix(1)) { send(request, sentAt: session.now) }
    }

    private func send(_ request: LiveRequest, sentAt: SessionTime) {
        inFlight.insert(request.source)
        requests += 1
        let client = self.client, meetingID = request.meetingID, generation = self.generation
        let timing = LiveTranscriptState.RequestTiming(sentAt: sentAt, segmentEnds: request.segments.map(\.interval.end))
        Task { @MainActor in
            defer { if self.generation == generation { inFlight.remove(request.source) } }
            do {
                if case .live(let r) = try await client.send(.live(request), timeout: .seconds(30)),
                   let session = self.session, session.meetingID == meetingID {
                    state.apply(r, sessionNow: session.now, timing: timing)
                    if Date().timeIntervalSince(lastPublish) > 30 { publishProvisional() }
                }
            } catch {
                // Worker restart or failure: the next tick resends from the last stable point.
            }
        }
    }

    /// Final-quality words decoded while recording (T19).
    func applyFinal(_ s: IncrementalResponse.Source) {
        guard session != nil else { return }
        state.applyFinal(source: s.source, words: s.newWords, until: .seconds(s.finalizedUntil))
    }

    static let producer = ProducerInfo(component: "live/parakeet-tdt-0.6b-v3", configHash: "live-v1")

    private func publishProvisional() {
        guard let store, let s = session else { return }
        if let rev = state.revision(meetingID: s.meetingID, producer: Self.producer) {
            try? store.publishTranscript(rev, provisional: true)
            lastPublish = Date()
        }
        Self.saveLatency(state, meetingID: s.meetingID, directory: s.directory, tick: interval, requests: requests)
    }

    /// Writes `live-latency.json` (metrics only) into the meeting's folder.
    static func saveLatency(_ st: LiveTranscriptState, meetingID: MeetingID, directory: URL, tick: Double, requests: Int) {
        guard !st.samples.isEmpty else { return }
        let log = LiveLatencyLog(meetingID: meetingID, tickSeconds: tick, requests: requests, samples: st.samples)
        try? ContractCoding.encode(log).write(to: directory.appending(path: LiveLatencyLog.fileName), options: .atomic)
    }
}
