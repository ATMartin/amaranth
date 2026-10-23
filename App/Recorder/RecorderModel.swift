import AppKit
import Foundation
import Observation
import Capture
import Domain
import Storage

/// Recorder state for the UI (T10). UI state is polled at 10 Hz from session snapshots — audio callbacks never publish
/// to SwiftUI. The scratchpad is private: saved as revisions on this Mac, excluded from notes/exports unless included.
@MainActor @Observable
final class RecorderModel {
    var selection: SourceSelection = SourceSelection(rawValue: UserDefaults.standard.string(forKey: "defaultSources") ?? "") ?? .both
    var microphoneUID: String? = UserDefaults.standard.string(forKey: "microphoneUID")
    var title = ""
    var scratchpad = ""
    private(set) var meetingID: MeetingID?
    /// Seconds of audio durably saved, per source.
    private(set) var savedUpTo: [SourceKind: Double] = [:]
    private(set) var diskSecondsLeft: Double?
    private(set) var diskWarned = false
    private var savedScratchpad = ""
    private var lastScratchpadSave = Date.distantPast
    /// Live provisional text while recording (T14).
    weak var live: LiveTextModel?
    /// Final-quality transcription while recording (T19).
    weak var incremental: IncrementalProcessor?
    /// Called with the saved meeting after Stop.
    var onFinished: ((MeetingID) -> Void)?
    private(set) var inputs: [AudioDeviceInfo] = []
    private(set) var state: CaptureState = .idle
    private(set) var elapsed: Double = 0
    private(set) var health: [SourceHealth] = []
    private(set) var lastResult: String?
    private(set) var error: String?
    private(set) var recoveryMessage: String?
    private var session: RecordingSession?
    private var poll: Timer?
    private var sleepObserver: (any NSObjectProtocol)?
    let store: MeetingStore?
    /// Set by the app: recording pauses heavy processing; a stopped meeting is queued for processing.
    weak var processing: ProcessingModel?

    init(store: MeetingStore? = try? MeetingStore(root: MeetingStore.defaultRoot()), recover: Bool = true) {
        self.store = store
        refreshDevices()
        if recover { recoverInterruptedRecordings() }
        // System sleep seals the recording and waits for an explicit resume; a locked screen does not interrupt.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.interrupt(reason: "system.sleep"); self?.tick() }
        }
    }

    /// Crash recovery at launch: indexes committed audio left by a crash/kill and marks those meetings interrupted.
    private func recoverInterruptedRecordings() {
        guard let store else { recoveryMessage = "Recording library unavailable."; return }
        Task.detached(priority: .utility) {
            let results = SegmentRecovery.recoverAll(store: store)
            let recovered = results.values.filter { !$0.report.reindexed.isEmpty || !$0.report.quarantined.isEmpty }
            guard !recovered.isEmpty else { return }
            let segs = recovered.map(\.report.reindexed.count).reduce(0, +)
            let damaged = recovered.map(\.report.damagedIntervals.count).reduce(0, +)
            let msg = "Recovered \(recovered.count) interrupted recording(s): \(segs) audio segment(s) restored"
                + (damaged > 0 ? ", \(damaged) damaged interval(s) marked" : "") + "."
            await MainActor.run { self.recoveryMessage = msg }
        }
    }

    func refreshDevices() { inputs = AudioDevices.inputs() }

    func start() {
        guard session == nil else { return }
        error = nil
        lastResult = nil
        state = .preparing
        let options = RecordingOptions(selection: selection, microphoneUID: microphoneUID)
        UserDefaults.standard.set(selection.rawValue, forKey: "defaultSources")
        UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID")
        let chosenTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        scratchpad = ""; savedScratchpad = ""; savedUpTo = [:]; diskWarned = false; diskSecondsLeft = nil
        // Starting capture can block while a TCC prompt is open: never on the main thread.
        let store = self.store
        Task.detached(priority: .userInitiated) {
            do {
                let root = store?.root ?? MeetingStore.defaultRoot()
                let title = chosenTitle.isEmpty ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : chosenTitle
                let s = try RecordingSession(meetingID: MeetingID(), rootDirectory: root, options: options, store: store, title: title)
                s.onAutoStop = { r in
                    Task { @MainActor in self.finish(r, note: "Stopped automatically to protect free disk space.") }
                }
                try s.start()
                await MainActor.run { self.attach(s) }
            } catch {
                await MainActor.run { self.state = .idle; self.error = "Could not start recording: \(error)" }
            }
        }
    }

    private func attach(_ s: RecordingSession) {
        session = s
        meetingID = s.meetingID
        live?.start(session: s, store: store)
        processing?.setRecording(true)
        if let store {
            incremental?.start(.init(meetingID: s.meetingID, meetingDirectory: s.directory,
                                     workDirectory: store.workDirectory(s.meetingID).appending(path: "incremental")) { [weak s] in
                s.map { snap in let r = snap.snapshot(); return (r.segments, r.events) }
            })
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let s = session else { return }
        state = s.state
        elapsed = s.now.seconds
        health = s.health()
        processing?.observeCapture(health)
        savedUpTo = s.lastCommitted().mapValues(\.seconds)
        let disk = s.diskStatus()
        diskSecondsLeft = disk.secondsLeft
        diskWarned = disk.warned
        if scratchpad != savedScratchpad, Date().timeIntervalSince(lastScratchpadSave) > 10 { saveScratchpad() }
    }

    private func saveScratchpad() {
        guard let store, let id = meetingID, scratchpad != savedScratchpad else { return }
        let include = (try? store.latestScratchpad(id))?.includeInSummary ?? false
        try? store.saveScratchpad(ScratchpadRevision(meetingID: id, text: scratchpad, includeInSummary: include, createdAt: Date()))
        savedScratchpad = scratchpad
        lastScratchpadSave = Date()
    }

    func pause() { session?.pause(); tick() }
    func resume() { session?.resume(); tick() }

    private var afterStop: [() -> Void] = []

    /// Stops and saves, then runs `then` (used by Quit).
    func stopThen(_ then: @escaping () -> Void) {
        // Not recording (or still starting): reply asynchronously so the caller has returned `.terminateLater` first.
        guard session != nil else { DispatchQueue.main.async(execute: then); return }
        afterStop.append(then)
        stop()
    }

    func stop() {
        guard let s = session else { return }
        poll?.invalidate()
        poll = nil
        state = .stopping
        Task.detached(priority: .userInitiated) {
            let r = s.stop()
            await MainActor.run { self.finish(r, note: nil) }
        }
    }

    private func finish(_ r: CaptureResult, note: String?) {
        poll?.invalidate()
        poll = nil
        saveScratchpad()
        if let live { Task { await live.finish(r) } }
        incremental?.stop()
        session = nil
        title = ""
        state = r.finalState
        processing?.setRecording(false)
        if !r.segments.isEmpty { processing?.enqueue(r.meetingID) }
        onFinished?(r.meetingID)
        let waiting = afterStop
        afterStop = []
        waiting.forEach { $0() }
        lastResult = [note, "Saved \(r.segments.count) segments (\(String(format: "%.0f", r.duration.seconds)) s) to \(r.directory.path)"
            + (r.events.contains(where: \.isMissingAudio) ? " · \(String(format: "%.1f", MeetingStatus.missingSeconds(r.events))) s missing (shown as gaps)" : "")]
            .compactMap { $0 }.joined(separator: " ")
    }
}
