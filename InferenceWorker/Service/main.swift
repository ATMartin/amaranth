import Foundation
import Domain
import ProcessingCore
import ProcessingRuntime

/// Bundled XPC inference worker. Runs processing stages with locally installed models; isolates model crashes from the
/// app and releases model/GPU memory when it exits. Messages carry job descriptors and output paths/hashes only.
final class WorkerService: NSObject, InferenceWorkerXPC, @unchecked Sendable {
    private let runner = StageRunner(models: ModelProvider.installedPack())
    private let lock = NSLock()
    private var tokens: [JobID: CancellationToken] = [:]
    private var stallNext = false
    weak var connection: NSXPCConnection?

    func send(_ request: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        let decoded: WorkerRequest
        do { decoded = try WorkerIPCCodec.decode(WorkerRequest.self, from: request) } catch {
            reply(nil, error as NSError)
            return
        }
        switch decoded {
        case .ping:
            reply(try? WorkerIPCCodec.encode(WorkerResponse.pong(pid: getpid(), contractVersion: ContractVersion.current)), nil)
        case .warmUp:
            let runner = self.runner
            Task {
                do {
                    try runner.warmUp()
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.acknowledged), nil)
                } catch {
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.failed(jobID: JobID("warmUp"), errorCode: String(describing: error).prefix(300).description)), nil)
                }
            }
        case .injectFault(let fault):
            handleFault(fault, reply: reply)
        case .live(let request):
            let runner = self.runner
            Task {
                do {
                    let r = try await runner.live(request)
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.live(r)), nil)
                } catch {
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.failed(jobID: JobID("live"), errorCode: String(describing: error).prefix(300).description)), nil)
                }
            }
        case .incremental(let request):
            let runner = self.runner
            Task {
                do {
                    let r = try await runner.incremental(request)
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.incremental(r)), nil)
                } catch {
                    reply(try? WorkerIPCCodec.encode(WorkerResponse.failed(jobID: JobID("incremental"), errorCode: String(describing: error).prefix(300).description)), nil)
                }
            }
        case .answer(let request):
            nonisolated(unsafe) let client = connection?.remoteObjectProxy as? any InferenceWorkerClientXPC
            let token = CancellationToken(), id = JobID(request.requestID)
            lock.withLock { tokens[id] = token }
            let runner = self.runner
            Task {
                defer { self.lock.withLock { self.tokens[id] = nil } }
                let response: WorkerResponse
                do {
                    response = .answer(try runner.answer(request, cancellation: token) { partial in
                        if let data = try? WorkerIPCCodec.encode(AnswerProgress(requestID: request.requestID, partial: partial)) { client?.answerProgress(data) }
                    })
                } catch is CancellationError {
                    response = .cancelled(jobID: id)
                } catch {
                    response = .failed(jobID: id, errorCode: String(describing: error).prefix(300).description)
                }
                reply(try? WorkerIPCCodec.encode(response), nil)
            }
        case .run(let job):
            // NSXPC proxies are thread-safe; the protocol just is not annotated Sendable.
            nonisolated(unsafe) let client = connection?.remoteObjectProxy as? any InferenceWorkerClientXPC
            let token = CancellationToken()
            lock.withLock { tokens[job.jobID] = token }
            let runner = self.runner
            if lock.withLock({ () -> Bool in defer { stallNext = false }; return stallNext }) {
                return // test fault: the job silently never progresses or replies
            }
            Task {
                defer { self.lock.withLock { self.tokens[job.jobID] = nil } }
                let response: WorkerResponse
                do {
                    response = try await runner.run(job, cancellation: token) { p in
                        if let data = try? WorkerIPCCodec.encode(p) { client?.progress(data) }
                    }
                } catch is CancellationError {
                    response = .cancelled(jobID: job.jobID)
                } catch {
                    response = .failed(jobID: job.jobID, errorCode: String(describing: error).prefix(300).description)
                }
                reply(try? WorkerIPCCodec.encode(response), nil)
            }
        }
    }

    func cancel(jobID: String) {
        lock.withLock { tokens[JobID(jobID)]?.cancel() }
    }

    private func handleFault(_ fault: WorkerFault, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        #if DEBUG
        switch fault {
        case .crash:
            abort() // simulates a model runtime crash
        case .hang:
            Thread.detachNewThread { while true { sleep(3600) } }
        case .stallNextJob:
            lock.withLock { stallNext = true }
            reply(try? WorkerIPCCodec.encode(WorkerResponse.acknowledged), nil)
        }
        #else
        reply(try? WorkerIPCCodec.encode(WorkerResponse.failed(jobID: JobID("fault"), errorCode: "faultInjection.disabled")), nil)
        #endif
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = WorkerService()
        service.connection = connection
        connection.exportedInterface = NSXPCInterface(with: (any InferenceWorkerXPC).self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: (any InferenceWorkerClientXPC).self)
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
