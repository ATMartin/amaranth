import Foundation
import Testing
import ProcessingCore

/// T118: the memory-pressure callback is created in a @MainActor context (ProcessingModel) but runs on a background
/// queue. Before the fix that combination trapped in swift_task_isCurrentExecutor (crash report 2026-11-05).
@MainActor
struct MemoryPressureMonitorTests {
    @Test func callbackCreatedOnMainActorRunsOffMainWithoutTrapping() async {
        let (stream, cont) = AsyncStream.makeStream(of: (Bool, Bool).self)
        let monitor = MemoryPressureMonitor(queue: .global()) { underPressure in
            cont.yield((underPressure, Thread.isMainThread))
        }
        monitor.start()
        defer { monitor.stop() }
        monitor.simulate(.warning)
        monitor.simulate(.normal)
        monitor.simulate(.critical)
        var seen: [(Bool, Bool)] = []
        for await r in stream { seen.append(r); if seen.count == 3 { break } }
        // A serial check isn't guaranteed on .global(); compare as a multiset of pressure values.
        #expect(seen.map(\.0).sorted { !$0 && $1 } == [false, true, true])
        #expect(seen.allSatisfy { !$0.1 }, "callback must run on the background queue")
    }

    @Test func classifiesEvents() {
        #expect(MemoryPressureMonitor.isUnderPressure(.warning))
        #expect(MemoryPressureMonitor.isUnderPressure(.critical))
        #expect(MemoryPressureMonitor.isUnderPressure([.warning, .normal]))
        #expect(!MemoryPressureMonitor.isUnderPressure(.normal))
    }
}
