public import Foundation

/// Watches system memory pressure and reports whether heavy work should pause.
///
/// T118: the handler runs on a background queue, so it must never be main-actor isolated. A closure written inside a
/// `@MainActor` type and handed to `DispatchSource.setEventHandler` (whose parameter is not `@Sendable`) is inferred
/// main-actor isolated, and Swift 6 traps at runtime when the source fires it off the main thread (crash report
/// 2026-11-05). Keeping the source here, in a nonisolated type, with a `@Sendable` callback, makes the compiler reject
/// that mistake instead.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let onChange: @Sendable (_ underPressure: Bool) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: (any DispatchSourceMemoryPressure)?

    /// `onChange` runs on `queue` with true for warning/critical and false once pressure returns to normal.
    public init(queue: DispatchQueue = .global(), onChange: @escaping @Sendable (_ underPressure: Bool) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    public func start() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: queue)
        src.setEventHandler { @Sendable [weak self, weak src] in
            guard let self, let src else { return }
            self.onChange(Self.isUnderPressure(src.data))
        }
        lock.withLock { source?.cancel(); source = src }
        src.resume()
    }

    public func stop() {
        lock.withLock { source?.cancel(); source = nil }
    }

    /// Delivers `event` on the monitor's queue exactly as the system source would (tests and `--self-test`).
    public func simulate(_ event: DispatchSource.MemoryPressureEvent) {
        let underPressure = Self.isUnderPressure(event)
        queue.async { [self] in onChange(underPressure) }
    }

    public static func isUnderPressure(_ event: DispatchSource.MemoryPressureEvent) -> Bool {
        event.contains(.warning) || event.contains(.critical)
    }
}
