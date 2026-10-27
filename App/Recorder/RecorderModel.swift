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
    /// Whether the scratchpad editor is open above the live transcript (T33). Closed by default; kept for the session.
    var scratchpadOpen = false
    private(set) var meetingID: MeetingID?
    /// The open recording's meeting folder (shown in the health popover, T34).
    private(set) var directory: URL?
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
    /// Called after the recording's meeting changed outside the session (an approved calendar link, T59).
    var onMeetingChanged: ((MeetingID) -> Void)?
    /// Calendar access, for the event suggestion at Record (T59). Never used to ask for access.
    weak var calendar: CalendarModel?
    /// The strip's calendar question (T59): only ever a question; `approve(_:)` is the one place it links.
    private(set) var eventPrompt: CalendarSuggestion.Prompt = .none
    /// Offered first in the next recording's prompt: the event a "meeting starting" reminder was clicked for (T61).
    var preferredEventID: String?
    /// The title this recording got automatically (nothing typed); nil when the user typed one.
    private var automaticTitle: String?
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

    #if DEBUG
    /// UI render self-test only: shows the recording strip without a capture session (state `nil` returns to idle).
    func showStripForRender(_ state: CaptureState?, elapsed: Double = 3723, health: [SourceHealth] = [], prompt: CalendarSuggestion.Prompt = .none) {
        self.state = state ?? .idle
        self.elapsed = state == nil ? 0 : elapsed
        self.health = state == nil ? [] : health
        eventPrompt = state == nil ? .none : prompt
    }

    /// Stop layout probe only (T67): the banner's "Saved …" line, as after a real Stop.
    func setResultForRender(_ text: String) { lastResult = text }
    #endif

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
        // `session` is set only after the async attach: also refuse while preparing (Return in the popover fires twice).
        guard !inSession else { return }
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
        automaticTitle = self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : nil
        eventPrompt = .none
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
        directory = s.directory
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
        offerEvents()
    }

    /// T59: once capture has started, ask about the calendar event happening now, if the setting is on and access was
    /// already granted (never asks for access here).
    private func offerEvents() {
        let preferred = preferredEventID
        preferredEventID = nil
        guard CalendarSettings.suggest(), let calendar else { return }
        calendar.refresh()
        guard calendar.status.canRead else { return }
        let source = calendar.source
        let now = Date()
        Task.detached(priority: .utility) {
            let w = CalendarSuggestion.window(at: now)
            let found = CalendarSuggestion.candidates(source.events(from: w.start, to: w.end, calendarIDs: nil), at: now, preferred: preferred)
            await MainActor.run { if self.session != nil { self.eventPrompt = CalendarSuggestion.Prompt(found) } }
        }
    }

    /// The user picked `event` in the strip (Link, or a choice under "Which meeting?"): link it, merge its attendees,
    /// and use its title only if the meeting still has its automatic title.
    func approve(_ event: CalendarEvent) {
        eventPrompt = .none
        guard let store, let id = meetingID else { return }
        let automatic = automaticTitle
        Task.detached(priority: .userInitiated) {
            do {
                try CalendarSuggestion.approve(event, for: id, in: store, automaticTitle: automatic)
            } catch {
                await MainActor.run { self.error = "Could not link the calendar event: \(error.localizedDescription)" }
            }
            await MainActor.run { self.onMeetingChanged?(id) }
        }
    }

    /// "Not this" / "None" / closing the prompt: nothing changes; the header chip can still link later.
    func dismissEventPrompt() { eventPrompt = .none }

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
        _ = try? RecordingScratchpad.save(scratchpad, for: id, in: store)
        savedScratchpad = scratchpad
        lastScratchpadSave = Date()
    }

    func pause() { session?.pause(); tick() }
    private var resuming = false

    func resume() {
        guard let s = session, !resuming else { return }
        guard s.state == .interrupted else { s.resume(); tick(); return }
        // Resuming after sleep restarts the sources, which can take over a second: never on the main thread.
        resuming = true
        Task.detached(priority: .userInitiated) {
            s.resume()
            await MainActor.run { self.resuming = false; self.tick() }
        }
    }

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
        eventPrompt = .none
        automaticTitle = nil
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
