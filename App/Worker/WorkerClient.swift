import Foundation
import Observation
import Domain

/// App-side connection to the bundled inference worker. Worker crashes surface as state changes and
/// errors on in-flight requests; they never terminate the app. The connection relaunches the worker on
/// the next message.
@MainActor @Observable
final class WorkerClient {
    enum ConnectionState: Equatable {
        case idle
        case connected(pid: Int32)
        /// Worker exited/crashed; it will be relaunched on the next request.
        case interrupted(count: Int)
        case invalidated
    }

    enum ClientError: Error, Equatable {
        case workerInterrupted
        case timedOut
        case remote(String)
    }

    private(set) var state: ConnectionState = .idle
    private(set) var interruptionCount = 0
    private(set) var lastProgress: WorkerProgress?
    private var connection: NSXPCConnection?
    /// PID reported by the worker's last pong; used to terminate a hung worker.
    private var workerPID: Int32?
    private nonisolated let progressSink = ProgressSink()

    init() {
        progressSink.onProgress = { @Sendable [weak self] p in Task { @MainActor in self?.lastProgress = p } }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(serviceName: WorkerIdentity.workerBundleID)
        c.remoteObjectInterface = NSXPCInterface(with: (any InferenceWorkerXPC).self)
        c.exportedInterface = NSXPCInterface(with: (any InferenceWorkerClientXPC).self)
        c.exportedObject = progressSink
        // XPC invokes these on its own queue: they must not inherit main-actor isolation.
        c.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.interruptionCount += 1
                self.state = .interrupted(count: self.interruptionCount)
            }
        }
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.state = .invalidated
            }
        }
        c.resume()
        connection = c
        return c
    }

    /// Sends one request. In-flight requests fail with `.workerInterrupted` if the worker dies, or
    /// `.timedOut` if it hangs (the connection is then recycled so a fresh worker starts).
    func send(_ request: WorkerRequest, timeout: Duration = .seconds(30)) async throws -> WorkerResponse {
        let payload = try WorkerIPCCodec.encode(request)
        let conn = ensureConnection()
        let once = ResumeOnce()
        let response: WorkerResponse = try await withCheckedThrowingContinuation { cont in
            once.set(cont)
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable _ in
                once.resume(throwing: ClientError.workerInterrupted)
            } as? any InferenceWorkerXPC
            guard let proxy else { once.resume(throwing: ClientError.remote("no proxy")); return }
            proxy.send(payload) { data, error in
                if let error { once.resume(throwing: ClientError.remote(error.localizedDescription)); return }
                do {
                    once.resume(returning: try WorkerIPCCodec.decode(WorkerResponse.self, from: data ?? Data()))
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard once.isPending else { return }
                // Recycle before failing the request so the caller's next request reaches a fresh worker.
                await MainActor.run { self.recycle(killWorker: true) }
                once.resume(throwing: ClientError.timedOut)
            }
        }
        if case .pong(let pid, _) = response {
            state = .connected(pid: pid)
            workerPID = pid
        }
        return response
    }

    /// Routes worker progress for `job` to `handler` (called off the main thread).
    nonisolated func register(_ job: JobID, handler: @escaping @Sendable (WorkerProgress) -> Void) { progressSink.register(job, handler) }
    nonisolated func unregister(_ job: JobID) { progressSink.unregister(job) }
    var currentWorkerPID: Int32? { workerPID }

    func cancel(_ job: JobID) {
        (connection?.remoteObjectProxy as? any InferenceWorkerXPC)?.cancel(jobID: job.rawValue)
    }

    /// Tears down the connection so a new worker starts on demand. A hung worker is killed outright:
    /// invalidating the connection alone does not stop a busy XPC service or release its model memory.
    func recycle(killWorker: Bool = false) {
        if killWorker, let pid = workerPID, pid > 0, pid != ProcessInfo.processInfo.processIdentifier {
            kill(pid, SIGKILL)
            workerPID = nil
        }
        connection?.invalidate()
        connection = nil
    }
}

private final class ProgressSink: NSObject, InferenceWorkerClientXPC, @unchecked Sendable {
    var onProgress: (@Sendable (WorkerProgress) -> Void)?
    private let lock = NSLock()
    private var handlers: [JobID: @Sendable (WorkerProgress) -> Void] = [:]
    func register(_ id: JobID, _ h: @escaping @Sendable (WorkerProgress) -> Void) { lock.withLock { handlers[id] = h } }
    func unregister(_ id: JobID) { lock.withLock { handlers[id] = nil } }
    /// Called on an XPC queue; routes to the job's handler without hopping to the main actor.
    func progress(_ update: Data) {
        guard let p = try? WorkerIPCCodec.decode(WorkerProgress.self, from: update) else { return }
        lock.withLock { handlers[p.jobID] }?(p)
        onProgress?(p)
    }
}

/// Guarantees a continuation is resumed exactly once across reply, error handler and timeout paths.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<WorkerResponse, any Error>?

    func set(_ c: CheckedContinuation<WorkerResponse, any Error>) {
        lock.withLock { cont = c }
    }

    @discardableResult
    func resume(returning v: WorkerResponse) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: v)
        return true
    }

    @discardableResult
    func resume(throwing e: any Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: e)
        return true
    }

    var isPending: Bool { lock.withLock { cont != nil } }

    private func take() -> CheckedContinuation<WorkerResponse, any Error>? {
        lock.withLock { defer { cont = nil }; return cont }
    }
}
