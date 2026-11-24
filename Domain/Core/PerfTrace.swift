public import Foundation
import os

/// T16 performance trace. Sub-stage intervals are emitted as `os_signpost` intervals (subsystem
/// `com.alexmartin.amaranth`, category `pipeline`; visible in Instruments) and summed per name into the task's current
/// trace, which the worker writes next to each stage output as `timing.json`. Tracing never changes stage outputs.
///
/// The current trace is a task-local: code running outside a traced task (tests, benches) records nothing but the
/// signposts. Detached tasks do not inherit it; record their results from the parent instead.
public final class PerfTrace: @unchecked Sendable {
    @TaskLocal public static var current: PerfTrace?
    static let signposter = OSSignposter(subsystem: "com.alexmartin.amaranth", category: "pipeline")

    /// Total wall seconds and number of intervals (or a plain counter when `seconds` is 0).
    public struct Entry: Codable, Sendable, Equatable {
        public var seconds: Double
        public var count: Int
        public init(seconds: Double, count: Int) { self.seconds = seconds; self.count = count }
    }

    public struct Snapshot: Codable, Sendable {
        public var entries: [String: Entry]
        public var notes: [String: String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var notes: [String: String] = [:]

    public init() {}

    public func add(_ name: String, seconds: Double, count: Int = 1) {
        lock.withLock {
            var e = entries[name] ?? Entry(seconds: 0, count: 0)
            e.seconds += seconds
            e.count += count
            entries[name] = e
        }
    }

    public func note(_ key: String, _ value: String) { lock.withLock { notes[key] = value } }

    public var snapshot: Snapshot { lock.withLock { Snapshot(entries: entries, notes: notes) } }
}

/// Recording helpers over `PerfTrace.current`.
public enum Perf {
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = PerfTrace.signposter.beginInterval(name)
        let t0 = ContinuousClock.now
        defer {
            PerfTrace.signposter.endInterval(name, state)
            PerfTrace.current?.add("\(name)", seconds: seconds(since: t0))
        }
        return try body()
    }

    @discardableResult
    public static func measure<T>(_ name: StaticString, isolation: isolated (any Actor)? = #isolation,
                                  _ body: () async throws -> T) async rethrows -> T {
        let state = PerfTrace.signposter.beginInterval(name)
        let t0 = ContinuousClock.now
        defer {
            PerfTrace.signposter.endInterval(name, state)
            PerfTrace.current?.add("\(name)", seconds: seconds(since: t0))
        }
        return try await body()
    }

    /// Adds externally measured time (e.g. timings reported by a dependency).
    public static func add(_ name: String, seconds: Double, count: Int = 1) { PerfTrace.current?.add(name, seconds: seconds, count: count) }

    public static func count(_ name: String, _ n: Int = 1) { PerfTrace.current?.add(name, seconds: 0, count: n) }

    public static func note(_ key: String, _ value: String) { PerfTrace.current?.note(key, value) }

    public static func seconds(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Worker-side timing of one stage execution, written as `timing.json` beside the stage output.
public struct StageTiming: Codable, Sendable {
    public static let fileName = "timing.json"
    public var stage: String
    public var wallSeconds: Double
    public var trace: PerfTrace.Snapshot
    public var workerPID: Int32
    /// Worker process age when the stage started (small = cold worker).
    public var workerUptimeSeconds: Double
    /// Thread QoS the stage ran at, and thermal state before/after.
    public var qos: String
    public var thermalStart: String
    public var thermalEnd: String
    /// "debug" when the processing code was compiled without optimisation.
    public var build: String
    public init(stage: String, wallSeconds: Double, trace: PerfTrace.Snapshot, workerPID: Int32, workerUptimeSeconds: Double, qos: String,
                thermalStart: String, thermalEnd: String, build: String) {
        self.stage = stage; self.wallSeconds = wallSeconds; self.trace = trace; self.workerPID = workerPID
        self.workerUptimeSeconds = workerUptimeSeconds; self.qos = qos; self.thermalStart = thermalStart; self.thermalEnd = thermalEnd
        self.build = build
    }
}

/// App-side timing of one job execution, written as `timing-scheduler.json` in the job's work directory.
public struct SchedulerTiming: Codable, Sendable {
    public static let fileName = "timing-scheduler.json"
    public var stage: String
    /// Seconds since 1970 (sub-second; contract dates are ISO 8601 whole seconds).
    public var queuedAt: Double
    public var startedAt: Double
    public var finishedAt: Double
    public var writeInputSeconds: Double
    /// Round trip through the executor (XPC worker), including the stage itself.
    public var executeSeconds: Double
    public var commitSeconds: Double
    public var state: String
    public var attempt: Int
    public init(stage: String, queuedAt: Date, startedAt: Date, finishedAt: Date, writeInputSeconds: Double, executeSeconds: Double,
                commitSeconds: Double, state: String, attempt: Int) {
        self.stage = stage; self.queuedAt = queuedAt.timeIntervalSince1970; self.startedAt = startedAt.timeIntervalSince1970
        self.finishedAt = finishedAt.timeIntervalSince1970
        self.writeInputSeconds = writeInputSeconds; self.executeSeconds = executeSeconds; self.commitSeconds = commitSeconds
        self.state = state; self.attempt = attempt
    }
}

extension ProcessInfo.ThermalState {
    public var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
