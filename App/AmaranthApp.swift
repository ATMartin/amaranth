import SwiftUI
import AppKit
import Presentation

@main
struct AmaranthEntry {
    @MainActor static func main() {
        if SelfTest.runIfRequested() {
            // Headless: keep the main run loop alive until the self-test exits the process.
            RunLoop.main.run()
            return
        }
        AmaranthApp.main()
    }
}

struct AmaranthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var worker: WorkerClient
    @State private var models: ModelSetupModel
    @State private var recorder: RecorderModel
    @State private var processing: ProcessingModel
    @State private var library: LibraryModel
    @State private var playback = PlaybackModel()
    @State private var live: LiveTextModel
    @State private var incremental: IncrementalProcessor

    init() {
        let worker = WorkerClient()
        let recorder = RecorderModel()
        let processing = ProcessingModel(store: recorder.store, worker: worker)
        let library = LibraryModel(store: recorder.store)
        recorder.processing = processing
        library.processing = processing
        processing.onChange = { [weak library] in library?.reload() }
        recorder.onStarted = { [weak library] id in library?.recordingStarted(id) }
        recorder.onFinished = { [weak library] id in library?.recordingStopped(id) }
        library.notesModelReady = ModelSetupModel.isReady
        AppDelegate.recorder = recorder
        let live = LiveTextModel(client: worker)
        recorder.live = live
        let modelsCheck = ModelSetupModel.isReady
        live.modelsReady = modelsCheck
        live.pauseReason = { [weak processing] in
            let t = ProcessInfo.processInfo.thermalState
            if t == .serious || t == .critical { return "Live text paused while the Mac is hot — recording continues" }
            if processing?.memoryPressure == true { return "Live text paused while memory is low — recording continues" }
            return nil
        }
        let incremental = IncrementalProcessor(client: worker)
        incremental.pauseReason = { [weak processing] in
            guard modelsCheck() else { return "Needs the model pack" }
            return processing?.incrementalPauseReason()
        }
        incremental.onFinal = { [weak live] s in live?.applyFinal(s) }
        recorder.incremental = incremental
        _incremental = State(initialValue: incremental)
        _live = State(initialValue: live)
        let models = ModelSetupModel()
        // Core ML compiles each model for this Mac on its first load (about 16 s for ASR): do it now, not on the first job.
        models.onInstalled = { Task { _ = try? await worker.send(.warmUp, timeout: .seconds(600)) } }
        _models = State(initialValue: models)
        _worker = State(initialValue: worker)
        _recorder = State(initialValue: recorder)
        _processing = State(initialValue: processing)
        _library = State(initialValue: library)
    }

    var body: some Scene {
        Window("Amaranth", id: "main") {
            Group {
                if OSVersionGate.isSupported && OSVersionGate.isSupportedArchitecture {
                    MainView()
                } else {
                    UnsupportedSystemView()
                }
            }
            .environment(worker)
            .environment(models)
            .environment(recorder)
            .environment(processing)
            .environment(library)
            .environment(playback)
            .environment(live)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { MeetingCommands(library: library) }

        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            // Visible whenever the app runs; red while recording so it is never silent.
            Image(systemName: recorder.state.isActive ? "record.circle.fill" : "waveform")
                .symbolRenderingMode(recorder.state.isActive ? .multicolor : .monochrome)
        }

        Settings {
            SettingsView(models: models, recorder: recorder)
        }
    }
}

/// Menu bar: always shows whether Amaranth is recording, for how long, and offers pause/resume/stop.
struct MenuBarContent: View {
    @Bindable var recorder: RecorderModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch recorder.state {
        case .recording: Text("Recording — \(RecorderPresentation.clock(recorder.elapsed))")
        case .paused: Text("Paused — \(RecorderPresentation.clock(recorder.elapsed))")
        case .interrupted: Text("Interrupted by sleep — audio saved")
        case .preparing: Text("Starting…")
        case .stopping: Text("Saving…")
        default: Text("Not recording")
        }
        Divider()
        if recorder.inSession {
            if recorder.state == .paused || recorder.state == .interrupted { Button("Resume") { recorder.resume() } }
            else { Button("Pause") { recorder.pause() }.disabled(recorder.state != .recording) }
            Button("Stop and Save") { recorder.stop() }.disabled(recorder.state == .stopping)
        } else {
            // Bring the window forward so the live transcript is in front (T32).
            Button("Record") { recorder.start(); openWindow(id: "main"); NSApp.activate() }
        }
        Divider()
        Button("Open Amaranth") { openWindow(id: "main"); NSApp.activate() }
        Button("Quit Amaranth") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Quitting while recording asks first and saves; closing the window keeps recording (the menu bar shows it).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var recorder: RecorderModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = Self.recorder, recorder.state.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Amaranth is recording"
        alert.informativeText = "Stop and save the recording before quitting? Everything recorded so far is already saved to disk."
        alert.addButton(withTitle: "Stop, Save and Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        recorder.stopThen { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct UnsupportedSystemView: View {
    var body: some View {
        ContentUnavailableView(
            "Unsupported Mac",
            systemImage: "exclamationmark.triangle",
            description: Text("Amaranth requires an Apple silicon (M2 or newer) Mac running macOS 26.5.2 or later. This Mac runs \(OSVersionGate.currentDescription).")
        )
        .frame(minWidth: 480, minHeight: 300)
    }
}
