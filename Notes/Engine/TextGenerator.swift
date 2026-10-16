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
