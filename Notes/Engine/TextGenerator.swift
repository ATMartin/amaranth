public import Foundation
public import Domain

/// A local text generator (llama.cpp in production; scripted fakes in tests). Output is plain text; the notes pipeline
/// parses and validates it. The generator has no tools and no side effects: transcript text can only ever become data.
public protocol TextGenerator: AnyObject, Sendable {
    var identity: ProducerInfo { get }
    var contextTokens: Int { get }
    func countTokens(_ text: String) -> Int
    /// Chat-formatted prompt for this model.
    func chatPrompt(system: String, user: String) -> String
    /// Greedy, optionally grammar-constrained generation. Stops at `maxTokens`, end of generation, or cancellation
    /// (checked per token, then reported by throwing `CancellationError`).
    func generate(prompt: String, grammar: String?, maxTokens: Int, cancellation: CancellationToken) throws -> GenerationResult
    /// Independent requests that may be decoded together (T18). `onResult` receives each result as soon as it is done, in
    /// any order, with its index in `requests`. A request is either completed or not reported at all: on cancellation or
    /// an engine error, the calls still in flight are dropped and the error is thrown.
    func generateBatch(_ requests: [GenerationRequest], cancellation: CancellationToken,
                       onResult: (Int, GenerationResult) throws -> Void) throws
    /// Like `generateBatch`, but each result may add follow-up requests (returned by `onResult`), which join the queue
    /// with the next indices. The call returns when the queue is empty.
    func generateStream(_ requests: [GenerationRequest], cancellation: CancellationToken,
                        onResult: (Int, GenerationResult) throws -> [GenerationRequest]) throws
}

public struct GenerationRequest: Sendable, Hashable {
    public var prompt: String
    public var grammar: String?
    public var maxTokens: Int
    public init(prompt: String, grammar: String?, maxTokens: Int) {
        self.prompt = prompt; self.grammar = grammar; self.maxTokens = maxTokens
    }
}

extension TextGenerator {
    /// One request at a time, in order (scripted generators and engines without batching).
    public func generateBatch(_ requests: [GenerationRequest], cancellation: CancellationToken,
                              onResult: (Int, GenerationResult) throws -> Void) throws {
        try generateStream(requests, cancellation: cancellation) { try onResult($0, $1); return [] }
    }

    public func generateStream(_ requests: [GenerationRequest], cancellation: CancellationToken,
                               onResult: (Int, GenerationResult) throws -> [GenerationRequest]) throws {
        var queue = requests
        var i = 0
        while i < queue.count {
            let r = queue[i]
            queue += try onResult(i, try generate(prompt: r.prompt, grammar: r.grammar, maxTokens: r.maxTokens, cancellation: cancellation))
            i += 1
        }
    }
}

public struct GenerationResult: Sendable {
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var hitTokenLimit: Bool
    public init(text: String, promptTokens: Int, generatedTokens: Int, hitTokenLimit: Bool) {
        self.text = text; self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.hitTokenLimit = hitTokenLimit
    }
}
