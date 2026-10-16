import Foundation
import Domain
import ProcessingCore

/// Runs scheduler jobs in the bundled XPC worker. A worker crash surfaces as `JobFailure.workerLost` (retried by the
/// scheduler); a worker that stops reporting progress for `hangTimeout` is killed and recycled, also `workerLost`.
final class WorkerExecutor: JobExecutor, @unchecked Sendable {
    let client: WorkerClient
    let hangTimeout: Duration

    init(client: WorkerClient, hangTimeout: Duration = .seconds(300)) {
        self.client = client
        self.hangTimeout = hangTimeout
    }

    func execute(_ job: JobDescriptor, progress: @escaping @Sendable (WorkerProgress) -> Void) async throws -> WorkerResponse {
        let beat = Heartbeat()
        client.register(job.jobID) { p in beat.touch(); progress(p) }
        defer { client.unregister(job.jobID) }
        // Learn the worker's pid first, so a hung worker can be killed.
        _ = try? await client.send(.ping, timeout: .seconds(10))
        let client = self.client, hang = self.hangTimeout
        do {
            return try await withThrowingTaskGroup(of: WorkerResponse.self) { group in
                group.addTask { try await client.send(.run(job), timeout: .seconds(24 * 3600)) }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .seconds(1))
                        if beat.idle > hang {
                            await client.recycle(killWorker: true)
                            throw JobFailure.workerLost("no progress for \(hang)")
                        }
                    }
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch let e as JobFailure {
            throw e
        } catch WorkerClient.ClientError.workerInterrupted {
            throw JobFailure.workerLost("worker exited")
        } catch WorkerClient.ClientError.timedOut {
            throw JobFailure.workerLost("timeout")
        } catch WorkerClient.ClientError.remote(let msg) {
            throw JobFailure.stageFailed(msg)
        }
    }

    func cancel(_ job: JobID) {
        let client = self.client
        Task { @MainActor in client.cancel(job) }
    }
}

final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now
    func touch() { lock.withLock { last = .now } }
    var idle: Duration { lock.withLock { ContinuousClock.now - last } }
}
