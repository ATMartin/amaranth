import Foundation
import Domain
import ProcessingCore
import Presentation

/// Headless checks runnable against the real app bundle: `Amaranth.app/Contents/MacOS/Amaranth --self-test worker-crash`.
/// Prints one JSON line per step and exits non-zero on failure. Used by scripts/selftest.sh and validators.
@MainActor
enum SelfTest {
    /// True when launched with `--self-test` (the app then must not touch notifications or other system state).
    static var isRequested: Bool { CommandLine.arguments.contains("--self-test") }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count else { return false }
        let name = args[i + 1]
        Task { @MainActor in
            let ok: Bool
            switch name {
            case "worker-crash": ok = await workerCrash()
            case "worker-hang": ok = await workerHang()
            case "os-gate": ok = osGate()
            case "capture-signals": ok = await CaptureSelfTest.signals()
            case "capture-routes": ok = await CaptureSelfTest.routes()
            case "pipeline-e2e": ok = await PipelineSelfTest.endToEnd()
            case "kill-worker-while-recording": ok = await PipelineSelfTest.killWorkerWhileRecording()
            case "hung-worker-recycled": ok = await PipelineSelfTest.hungWorkerIsRecycled()
            case "capture-tone":
                func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
                ok = await CaptureSelfTest.tone(hz: Double(arg("--hz") ?? "1234") ?? 1234, seconds: Double(arg("--seconds") ?? "10") ?? 10,
                                                label: arg("--label") ?? "external",
                                                selection: arg("--sources") == "both" ? .both : .systemOnly)
            case "processing-timing":
                let minutes = args.firstIndex(of: "--minutes").flatMap { Double(args[$0 + 1]) } ?? 60
                let out = args.firstIndex(of: "--self-test-output").flatMap { $0 + 1 < args.count ? URL(filePath: args[$0 + 1]) : nil }
                ok = await QualificationSelfTest.processingTiming(minutes: minutes, output: out)
            case "perf-run":
                guard let spec = args.firstIndex(of: "--perf-spec").flatMap({ $0 + 1 < args.count ? URL(filePath: args[$0 + 1]) : nil }) else {
                    log(["step": "usage", "error": "--perf-spec <spec.json> required"]); ok = false; break
                }
                ok = await PerfSelfTest.run(specURL: spec)
            case "live-replay":
                guard let spec = args.firstIndex(of: "--live-spec").flatMap({ $0 + 1 < args.count ? URL(filePath: args[$0 + 1]) : nil }) else {
                    log(["step": "usage", "error": "--live-spec <spec.json> required"]); ok = false; break
                }
                ok = await LiveReplaySelfTest.run(specURL: spec)
            case "live-latency": ok = await LiveSelfTest.run()
            case "live-pressure": ok = await LiveSelfTest.run(pressure: true)
            case "live-load": ok = await LiveSelfTest.run(load: true)
            case "ui-render":
                let out = args.firstIndex(of: "--self-test-output").flatMap { $0 + 1 < args.count ? URL(filePath: args[$0 + 1]) : nil }
                let size = TextSize(stored: args.firstIndex(of: "--text-size").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
                ok = await UIRenderSelfTest.run(outputDirectory: out, textSize: size)
            case "ui-density": ok = await UIDensitySelfTest.run(args: args)
            case "ask-worker": ok = await AskWorkerSelfTest.run()
            case "calendar-access": ok = await CalendarSelfTest.run()
            case "capture-soak":
                let minutes = args.firstIndex(of: "--minutes").flatMap { Double(args[$0 + 1]) } ?? 30
                ok = await CaptureSelfTest.soak(minutes: minutes)
            default:
                log(["step": "unknown", "name": name]); ok = false
            }
            log(["result": ok ? "pass" : "fail", "test": name])
            exit(ok ? 0 : 1)
        }
        return true
    }

    /// When launched via `open` (needed so TCC attributes permissions to Amaranth), stdout is not visible;
    /// `--self-test-output <path>` appends JSON lines to a file instead.
    static let outputHandle: FileHandle? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--self-test-output"), i + 1 < args.count else { return nil }
        FileManager.default.createFile(atPath: args[i + 1], contents: nil)
        return FileHandle(forWritingAtPath: args[i + 1])
    }()

    static func log(_ fields: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self)
        print(line)
        fflush(stdout)
        if let h = outputHandle { h.write(Data((line + "\n").utf8)); try? h.synchronize() }
    }

    static func osGate() -> Bool {
        log(["step": "os", "version": OSVersionGate.currentDescription, "supported": "\(OSVersionGate.isSupported)",
             "arm64": "\(OSVersionGate.isSupportedArchitecture)"])
        return OSVersionGate.isSupported && OSVersionGate.isSupportedArchitecture
    }

    /// 1. ping worker, 2. inject crash, 3. observe interruption without the app dying, 4. ping a relaunched worker
    /// (different pid), 5. run a job to completion on the fresh worker.
    static func workerCrash() async -> Bool {
        let client = WorkerClient()
        let appPID = ProcessInfo.processInfo.processIdentifier
        guard case .pong(let pid1, _)? = try? await client.send(.ping) else { log(["step": "ping1", "ok": "false"]); return false }
        log(["step": "ping1", "workerPID": "\(pid1)", "appPID": "\(appPID)"])

        do {
            _ = try await client.send(.injectFault(.crash), timeout: .seconds(10))
            log(["step": "crash", "error": "worker replied instead of crashing"])
            return false
        } catch {
            log(["step": "crash", "observedError": "\(error)"])
        }
        // Interruption handler runs asynchronously on the main actor.
        for _ in 0..<50 where client.interruptionCount == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        log(["step": "interruption", "count": "\(client.interruptionCount)", "appStillRunning": "true"])
        guard client.interruptionCount >= 1 else { return false }

        guard case .pong(let pid2, _)? = try? await client.send(.ping) else { log(["step": "ping2", "ok": "false"]); return false }
        log(["step": "ping2", "workerPID": "\(pid2)", "relaunched": "\(pid2 != pid1)"])
        guard pid2 != pid1 else { return false }

        // A real (cheap, model-free) stage on the relaunched worker: reconcile an empty transcript.
        let dir = FileManager.default.temporaryDirectory.appending(path: "amaranth-selftest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let meeting = MeetingID()
        let empty = TranscriptRevision(meetingID: meeting, kind: .final, stage: .asr, createdAt: Date(),
                                       producer: ProducerInfo(component: "selftest", configHash: "selftest"), segments: [], coverage: [])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try StageFiles.write(StageInput.reconcile(ReconcileInput(meetingID: meeting, asr: empty, diarization: DiarizeOutput(results: [], echoDelay: nil),
                                                                         edits: [], previous: nil, microphoneMode: .personal)),
                                     to: dir.appending(path: StageFiles.input))
        } catch { log(["step": "job", "setup": "\(error)"]); return false }
        let job = JobDescriptor(jobID: JobID(), key: JobKey(meetingID: meeting, stage: .reconcile, inputHash: "selftest", configHash: "selftest"),
                                workDirectory: dir)
        let reply = try? await client.send(.run(job))
        guard case .completed(_, let url, _)? = reply else { log(["step": "job", "ok": "false", "reply": "\(String(describing: reply))"]); return false }
        log(["step": "job", "output": url.lastPathComponent])
        return true
    }

    /// A hung worker is detected by timeout and recycled; the next request reaches a fresh worker.
    static func workerHang() async -> Bool {
        let client = WorkerClient()
        guard case .pong(let pid1, _)? = try? await client.send(.ping) else { return false }
        do {
            _ = try await client.send(.injectFault(.hang), timeout: .seconds(2))
            return false
        } catch WorkerClient.ClientError.timedOut {
            log(["step": "hang", "detected": "timeout"])
        } catch {
            log(["step": "hang", "unexpected": "\(error)"])
            return false
        }
        guard case .pong(let pid2, _)? = try? await client.send(.ping) else { log(["step": "ping2", "ok": "false"]); return false }
        log(["step": "ping2", "workerPID": "\(pid2)", "previousPID": "\(pid1)"])
        return pid2 != pid1
    }
}
