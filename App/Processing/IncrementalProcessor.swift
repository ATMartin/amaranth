import Foundation
import Observation
import Domain

/// Drives final-quality transcription while a meeting records (T19). Every `interval` seconds it sends the segments
/// committed since the worker's last reply (durable audio only, from the recording's snapshot) with a time budget, one
/// request in flight at a time. It backs off whenever `pauseReason` gives a reason (setting off, hot Mac, memory
/// pressure, a capture fault); capture itself is never touched. At Stop the transcription stage reuses what was done.
@MainActor @Observable
final class IncrementalProcessor {
    enum Status: Equatable { case off, running, paused(String) }

    struct Stats: Sendable, Codable {
        var requests = 0
        var busyReplies = 0
        var failures = 0
        var pausedTicks = 0
        var workSeconds = 0.0
        var finalizedUntil: [String: Double] = [:]
        var settledUntil: [String: Double] = [:]
        var decodedWindows = 0
        var plannedWindows = 0
    }

    struct Recording {
        var meetingID: MeetingID
        var meetingDirectory: URL
        var workDirectory: URL
        /// Committed segments and capture events so far (nil once the recording is gone).
        var snapshot: () -> (segments: [AudioSegmentRecord], events: [CaptureEvent])?
    }

    private(set) var status: Status = .off
    private(set) var stats = Stats()
    let client: WorkerClient
    let interval: Double
    /// Worker time per request. Short, so a request never holds the decoder long and stays cheap to cancel at Stop.
    let budget: Double
    /// Returns a reason to pause, or nil.
    var pauseReason: () -> String? = { nil }
    /// Final-quality words as they become available (live text shows them in place of provisional words).
    var onFinal: ((IncrementalResponse.Source) -> Void)?
    private var recording: Recording?
    private var timer: Timer?
    private var inFlight = false
    private var lastSequence: [SourceKind: Int64] = [:]

    init(client: WorkerClient, interval: Double = 5, budget: Double = 3) {
        self.client = client
        self.interval = interval
        self.budget = budget
    }

    func start(_ r: Recording) {
        stop()
        recording = r
        stats = Stats()
        lastSequence = [:]
        status = .running
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops sending and tells the worker to drop the meeting's state (cancelling work in progress).
    func stop() {
        timer?.invalidate(); timer = nil
        if let r = recording {
            let client = self.client
            Task { _ = try? await client.send(.incremental(IncrementalRequest(meetingID: r.meetingID, meetingDirectory: r.meetingDirectory,
                                                                             workDirectory: r.workDirectory, segments: [], events: [],
                                                                             budgetSeconds: 0, close: true)), timeout: .seconds(10)) }
        }
        recording = nil
        status = .off
    }

    func tick() {
        guard let r = recording, !inFlight else { return }
        if let why = pauseReason() { status = .paused(why); stats.pausedTicks += 1; return }
        status = .running
        guard let snap = r.snapshot() else { return }
        // Segments the worker does not have yet (a fresh worker gets them all, in bounded batches), plus each source's
        // first segment, so a worker that lost its state always knows where a source starts.
        let committed = snap.segments.filter { $0.state == .committed }.sorted { $0.sequence < $1.sequence }
        let bySource = Dictionary(grouping: committed, by: \.source)
        let batch = bySource.values.flatMap { segs in
            let fresh = segs.filter { s in lastSequence[s.source].map { s.sequence > $0 } ?? true }.prefix(600)
            return (fresh.first?.id == segs.first?.id ? [] : Array(segs.prefix(1))) + fresh
        }
        let request = IncrementalRequest(meetingID: r.meetingID, meetingDirectory: r.meetingDirectory, workDirectory: r.workDirectory,
                                         segments: batch, events: snap.events, budgetSeconds: budget)
        inFlight = true
        stats.requests += 1
        let client = self.client, t0 = ContinuousClock.now
        Task { @MainActor in
            defer { inFlight = false }
            do {
                let response = try await client.send(.incremental(request), timeout: .seconds(budget + 60))
                stats.workSeconds += Perf.seconds(since: t0)
                guard self.recording?.meetingID == r.meetingID else { return }
                switch response {
                case .incremental(let reply) where reply.busy: stats.busyReplies += 1
                case .incremental(let reply):
                    // The worker's state is the truth (after a worker restart it starts again from the first segment).
                    lastSequence = Dictionary(uniqueKeysWithValues: reply.sources.compactMap { s in s.lastSequence.map { (s.source, $0) } })
                    for s in reply.sources {
                        stats.finalizedUntil[s.source.rawValue] = s.finalizedUntil
                        stats.settledUntil[s.source.rawValue] = s.settledUntil
                        onFinal?(s)
                    }
                    stats.decodedWindows = reply.sources.map(\.decodedWindows).reduce(0, +)
                    stats.plannedWindows = reply.sources.map(\.plannedWindows).reduce(0, +)
                default: stats.failures += 1
                }
            } catch {
                // Worker restart: it lost its state, so resend everything next time.
                stats.failures += 1
                lastSequence = [:]
            }
        }
    }
}
