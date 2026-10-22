import Foundation
import Observation
import Domain
import ProcessingCore
import Storage

/// Owns the job scheduler in the app. Heavy stages pause while recording or under thermal/memory pressure. Every job
/// state change triggers a (throttled) library refresh, so the UI shows queued/paused/running/failed, never "stuck".
@MainActor @Observable
final class ProcessingModel {
    private(set) var error: String?
    let store: MeetingStore?
    private(set) var scheduler: JobScheduler?
    private let flags = PressureFlags()
    private var memorySource: (any DispatchSourceMemoryPressure)?
    private var refreshPending = false
    /// Called (throttled, on the main actor) after job changes.
    var onChange: (() -> Void)?

    static var microphoneMode: MicrophoneMode {
        MicrophoneMode(rawValue: UserDefaults.standard.string(forKey: "microphoneMode") ?? "") ?? .personal
    }

    /// T17 rollback switch: off runs transcription and speaker separation one after the other, as before.
    static var concurrentAnalysis: Bool {
        UserDefaults.standard.object(forKey: "concurrentAnalysis") as? Bool ?? true
    }

    init(store: MeetingStore?, worker: WorkerClient) {
        self.store = store
        guard let store else { return }
        let flags = self.flags
        let config = JobScheduler.Configuration(asrConfigHash: PipelineVersions.asr, diarizationConfigHash: PipelineVersions.diarization,
                                                notesConfigHash: PipelineVersions.notes, microphoneMode: Self.microphoneMode,
                                                concurrentAnalysis: Self.concurrentAnalysis)
        let s = JobScheduler(store: store, executor: WorkerExecutor(client: worker), configuration: config) {
            .current(recording: flags.recording, thermal: ProcessInfo.processInfo.thermalState, memoryPressure: flags.memoryPressure)
        }
        s.onChange = { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
        do { try s.start() } catch { self.error = "Processing unavailable: \(error)" }
        scheduler = s
        // Memory pressure suspends heavy work until it clears (re-checked by the scheduler loop).
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .global())
        src.setEventHandler { [weak src] in
            guard let src else { return }
            flags.memoryPressure = src.data.contains(.warning) || src.data.contains(.critical)
            s.poke()
        }
        src.resume()
        memorySource = src
        // Thermal changes are re-evaluated by the scheduler; poke it so a cooled-down Mac resumes promptly.
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in s.poke() }
    }

    /// Recording state from the recorder: heavy processing yields to capture.
    func setRecording(_ active: Bool) {
        flags.recording = active
        scheduler?.poke()
        scheduleRefresh()
    }

    func enqueue(_ meeting: MeetingID) {
        do { try scheduler?.enqueuePipeline(meeting) } catch { self.error = "Could not queue processing: \(error)" }
        scheduleRefresh()
    }

    func retry(_ meeting: MeetingID) {
        guard let store else { return }
        for var j in (try? store.jobs(meeting: meeting, states: [.failed, .cancelled])) ?? [] where j.errorCode != "audio.deleted" {
            try? j.transition(to: .queued, at: Date())
            j.notBefore = nil
            try? store.upsertJob(j)
        }
        scheduler?.poke()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            refreshPending = false
            onChange?()
        }
    }
}

final class PressureFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _recording = false, _memory = false
    var recording: Bool { get { lock.withLock { _recording } } set { lock.withLock { _recording = newValue } } }
    var memoryPressure: Bool { get { lock.withLock { _memory } } set { lock.withLock { _memory = newValue } } }
}
