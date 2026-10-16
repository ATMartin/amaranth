import Foundation
import Observation
import Capture
import Domain
import Presentation
import Storage

/// Drives live text while recording (T14). Every `interval` seconds it sends each source's newly committed segments
/// (from `RecordingSession.snapshot()`, i.e. durable audio only) to the worker, one request in flight at a time, and
/// merges the result. It pauses under thermal/memory pressure or when models are missing; capture is never affected.
@MainActor @Observable
final class LiveTextModel {
    enum Status: Equatable { case off, running, paused(String), unavailable(String) }
    private(set) var state = LiveTranscriptState()
    private(set) var status: Status = .off
    private var session: RecordingSession?
    private var store: MeetingStore?
    private var timer: Timer?
    private var inFlight = false
    private var lastPublish = Date.distantPast
    let client: WorkerClient
    let interval: Double
    /// Returns a reason to pause (pressure), or nil.
    var pauseReason: () -> String? = {
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical ? "Live text paused while the Mac is hot — recording continues" : nil
    }
    var modelsReady: () -> Bool = { true }

    init(client: WorkerClient, interval: Double = 2.0) {
        self.client = client
        self.interval = interval
    }

    func start(session: RecordingSession, store: MeetingStore?) {
        stop(publish: false)
        self.session = session
        self.store = store
        state = LiveTranscriptState()
        guard modelsReady() else { status = .unavailable("Live text needs the model pack — recording works without it"); return }
        status = .running
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops polling; publishes the provisional revision so it is visible until the final transcript replaces it.
    func stop(publish: Bool = true) {
        timer?.invalidate(); timer = nil
        if publish { publishProvisional() }
        session = nil
        if status == .running { status = .off }
    }

    private func tick() {
        guard let session, !inFlight, session.state == .recording else { return }
        if let why = pauseReason() { status = .paused(why); return }
        if case .paused = status { status = .running }
        let snapshot = session.snapshot()
        let st = state
        // Round-robin over sources that have new committed audio.
        let candidates = SourceKind.allCases.compactMap { kind -> LiveRequest? in
            let stable = st.stableUntil(kind)
            let segs = snapshot.segments.filter { $0.source == kind && $0.interval.end.seconds > stable.seconds - 2.5 }
            guard let end = segs.map(\.interval.end).max(), end.seconds - (st.sources[kind]?.processedUntil.seconds ?? 0) >= 0.5 else { return nil }
            return LiveRequest(meetingID: session.meetingID, meetingDirectory: session.directory, source: kind, stableUntil: stable, segments: segs)
        }.sorted { (st.sources[$0.source]?.processedUntil ?? .zero) < (st.sources[$1.source]?.processedUntil ?? .zero) }
        guard let request = candidates.first else { return }
        inFlight = true
        let client = self.client
        Task { @MainActor in
            defer { inFlight = false }
            do {
                if case .live(let r) = try await client.send(.live(request), timeout: .seconds(30)) {
                    let now = self.session?.now ?? r.processedUntil
                    state.apply(r, sessionNow: now)
                    if Date().timeIntervalSince(lastPublish) > 30 { publishProvisional() }
                }
            } catch {
                // Worker restart or failure: the next tick resends from the last stable point.
            }
        }
    }

    private func publishProvisional() {
        guard let store, let s = session else { return }
        if let rev = state.revision(meetingID: s.meetingID, producer: ProducerInfo(component: "live/parakeet-tdt-0.6b-v3", configHash: "live-v1")) {
            try? store.publishTranscript(rev, provisional: true)
            lastPublish = Date()
        }
    }
}
