import Foundation
import Storage

/// `--self-test memory-pressure` (T118): builds the real ProcessingModel on a temporary library and fires its
/// memory-pressure monitor on a background queue, as the system does. Before T118 the first event trapped the app
/// (main-actor isolation check, crash report 2026-11-05). Passes when the app survives warning → normal → critical →
/// normal and the pause flag follows each event. The real system path is covered by the hands-on check
/// `sudo memory_pressure -S -l warn` / `-l critical` against a running app.
enum MemoryPressureSelfTest {
    @MainActor static func run() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-selftest-mp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = try? MeetingStore(root: root) else { SelfTest.log(["step": "store", "error": "failed"]); return false }
        let model = ProcessingModel(store: store, worker: WorkerClient())
        guard let monitor = model.memoryMonitor else { SelfTest.log(["step": "monitor", "error": "missing"]); return false }
        var ok = true
        for (event, expected) in [(DispatchSource.MemoryPressureEvent.warning, true), (.normal, false), (.critical, true), (.normal, false)] {
            monitor.simulate(event)
            var observed = !expected
            for _ in 0..<50 {
                observed = model.memoryPressure
                if observed == expected { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            SelfTest.log(["step": "event", "event": "\(event.rawValue)", "expected": "\(expected)", "observed": "\(observed)",
                          "pauseReason": model.incrementalPauseReason() ?? "none"])
            ok = ok && observed == expected
        }
        model.scheduler?.stop()
        return ok
    }
}
