import Domain
import Foundation
import Notes

// T18: run the notes pipeline on one transcript and log every model call (prompt, grammar, output, timings) as JSONL,
// so speed levers can be simulated against real calls and outputs compared across engine settings.
//
//   amaranth-bench notes-trace <model.gguf> <transcript.json> <out.jsonl> [--work dir] [--parallel 16] [--kv 24576]
//                              [--non-thinking] [--summary out.json]
enum NotesTrace {
    struct Call: Codable {
        var prompt: String
        var grammar: String?
        var maxTokens: Int
        var text: String
        var promptTokens: Int
        var generatedTokens: Int
        var seconds: Double
    }

    final class Recorder: TextGenerator, @unchecked Sendable {
        let inner: any TextGenerator
        let out: FileHandle
        init(_ inner: any TextGenerator, out: FileHandle) { self.inner = inner; self.out = out }
        var identity: ProducerInfo { inner.identity }
        var contextTokens: Int { inner.contextTokens }
        func countTokens(_ text: String) -> Int { inner.countTokens(text) }
        func chatPrompt(system: String, user: String) -> String { inner.chatPrompt(system: system, user: user) }
        func generate(prompt: String, grammar: String?, maxTokens: Int, cancellation: CancellationToken) throws -> GenerationResult {
            let t0 = ContinuousClock.now
            let r = try inner.generate(prompt: prompt, grammar: grammar, maxTokens: maxTokens, cancellation: cancellation)
            let call = Call(prompt: prompt, grammar: grammar, maxTokens: maxTokens, text: r.text, promptTokens: r.promptTokens,
                            generatedTokens: r.generatedTokens, seconds: LlmProbe.secs(t0))
            out.write(try JSONEncoder().encode(call) + Data("\n".utf8))
            return r
        }
        func generateBatch(_ requests: [GenerationRequest], cancellation: CancellationToken,
                           onResult: (Int, GenerationResult) throws -> Void) throws {
            let t0 = ContinuousClock.now
            try inner.generateBatch(requests, cancellation: cancellation) { i, r in
                let q = requests[i]
                let call = Call(prompt: q.prompt, grammar: q.grammar, maxTokens: q.maxTokens, text: r.text, promptTokens: r.promptTokens,
                                generatedTokens: r.generatedTokens, seconds: LlmProbe.secs(t0))   // seconds since the batch started
                out.write(try JSONEncoder().encode(call) + Data("\n".utf8))
                try onResult(i, r)
            }
        }
    }

    static func run(gguf: URL, transcript: URL, output: URL, work: URL?, configuration: LlamaRunner.Configuration, nonThinking: Bool,
                    summary: URL?) throws {
        let tr = try ContractCoding.decode(TranscriptRevision.self, from: Data(contentsOf: transcript))
        let runner = try LlamaRunner(gguf: gguf, manifestID: ModelManifestID(gguf.deletingPathExtension().lastPathComponent.lowercased()),
                                     revision: "local", configuration: configuration,
                                     nonThinkingPrefix: nonThinking ? "<think>\n\n</think>\n\n" : "")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let fh = try FileHandle(forWritingTo: output)
        defer { try? fh.close() }
        let dir = work ?? FileManager.default.temporaryDirectory.appending(path: "notes-trace-\(UUID().uuidString)")
        let pipeline = NotesPipeline(generator: Recorder(runner, out: fh), workDirectory: dir)
        let t0 = ContinuousClock.now
        let rev = try pipeline.run(meetingID: tr.meetingID, transcript: tr, editSequence: 0, scratchpad: nil, cancellation: CancellationToken())
        let c = rev.content
        print(String(format: "notes %.1f s; items: %d decisions, %d actions, %d questions, %d topics, %d overview; uncertain %d",
                     LlmProbe.secs(t0), c.decisions.count, c.actionItems.count, c.openQuestions.count, c.topics.count, c.overview.count,
                     rev.validation.uncertainItemCount))
        for m in rev.validation.messages { print("  \(m)") }
        print(String(format: "  footprint %.0f MiB", AsrConcurrency.footprintMiB()))
        if let summary { try ContractCoding.encode(rev).write(to: summary) }
    }
}
