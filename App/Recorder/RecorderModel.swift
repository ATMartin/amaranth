import AppKit
import Foundation
import Observation
import Capture
import Domain
import Storage
import Presentation

/// Recorder state for the UI (T10). UI state is polled at 10 Hz from session snapshots — audio callbacks never publish
/// to SwiftUI. The scratchpad is private: saved as revisions on this Mac, excluded from notes/exports unless included.
@MainActor @Observable
final class RecorderModel {
    /// Per-recording sources and microphone. They follow the Settings defaults (T30) until changed for this meeting
    /// (`customized`), and return to the defaults after each recording.
    var selection: SourceSelection = RecordingDefaults.sources() { didSet { if !loadingDefaults { customized = true } } }
    var microphoneUID: String? = RecordingDefaults.microphone() { didSet { if !loadingDefaults { customized = true } } }
    private(set) var customized = false
    private var loadingDefaults = false
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
    /// Called with the new meeting once recording has started, and with the saved meeting after Stop.
    var onStarted: ((MeetingID) -> Void)?
    var onFinished: ((MeetingID) -> Void)?
    private(set) var inputs: [AudioDeviceInfo] = []
    private(set) var state: CaptureState = .idle
    private(set) var elapsed: Double = 0
    private(set) var health: [SourceHealth] = []
    private(set) var lastResult: String?
    private(set) var error: String?
    private(set) var recoveryMessage: String?
    /// One-line notice for this recording, e.g. the chosen microphone is not connected (T30).
    private(set) var notice: String?
    private var permissionDismissed = false
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

    /// A recording session is open: recording, paused, starting, saving, or interrupted by sleep and waiting to resume.
    var inSession: Bool { session != nil || state.isActive }

    enum Message: Hashable { case error, permission, notice, recovery, result }

    struct BannerItem {
        let kind: Message
        let text: String
        var isError: Bool { kind == .error || kind == .permission }
        var symbol: String {
            switch kind {
            case .error, .permission: "exclamationmark.triangle"
            case .notice: "mic.badge.xmark"
            case .recovery: "arrow.uturn.backward.circle"
            case .result: "checkmark.circle"
            }
        }
    }

    /// Messages for the banner above the detail pane (T31), most urgent first.
    var bannerItems: [BannerItem] {
        var items: [BannerItem] = []
        if let error { items.append(.init(kind: .error, text: error)) }
        if !permissionDismissed, health.contains(where: { $0.status == .permissionDenied }) {
            items.append(.init(kind: .permission, text: "Amaranth isn't allowed to record \(health.filter { $0.status == .permissionDenied }.map { RecorderPresentation.sourceName($0.source).lowercased() }.joined(separator: " or ")). Allow it in System Settings → Privacy & Security."))
        }
        if let notice { items.append(.init(kind: .notice, text: notice)) }
        if let recoveryMessage { items.append(.init(kind: .recovery, text: recoveryMessage)) }
        if let lastResult { items.append(.init(kind: .result, text: lastResult)) }
        return items
    }

    func dismiss(_ m: Message) {
        switch m {
        case .error: error = nil
        case .permission: permissionDismissed = true
        case .notice: notice = nil
        case .recovery: recoveryMessage = nil
        case .result: lastResult = nil
        }
    }

    /// Resets the per-recording choice to the Settings defaults (no-op while recording).
    func loadDefaults() {
        guard session == nil, !state.isActive else { return }
        loadingDefaults = true
        selection = RecordingDefaults.sources()
        microphoneUID = RecordingDefaults.microphone()
        loadingDefaults = false
        customized = false
    }

    func start() {
        guard session == nil else { return }
        error = nil
        lastResult = nil
        notice = nil
        permissionDismissed = false
        if !customized { loadDefaults() }
        refreshDevices()
        // A saved microphone that is unplugged must not block recording: use System default and say so once.
        let mic = RecordingDefaults.resolveMicrophone(microphoneUID, sources: selection, connected: inputs.map(\.uid))
        notice = mic.notice
        state = .preparing
        let options = RecordingOptions(selection: selection, microphoneUID: mic.uid)
        let title = RecorderPresentation.recordingTitle(typed: self.title, at: Date())
        scratchpad = ""; savedScratchpad = ""; savedUpTo = [:]; diskWarned = false; diskSecondsLeft = nil
        // Starting capture can block while a TCC prompt is open: never on the main thread.
        let store = self.store
        Task.detached(priority: .userInitiated) {
            do {
                let root = store?.root ?? MeetingStore.defaultRoot()
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
        onStarted?(s.meetingID)
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
        loadDefaults()
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
