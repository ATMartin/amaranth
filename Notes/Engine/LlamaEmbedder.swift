public import Foundation
public import Domain
import Accelerate
import llama

/// Text embeddings for contextual search (spec 0010, T110) with the pinned llama.cpp b11669 runtime and a verified
/// local GGUF (Qwen3-Embedding-0.6B Q8_0). Follows the model card's recipe: queries carry a one-line task instruction
/// (`Instruct: <task>\nQuery:<text>`), documents none; the input ends with `<|endoftext|>`; the vector is the last
/// token's hidden state (last-token pooling), optionally truncated to fewer dimensions (MRL), then L2-normalized.
/// Every setting that changes the vector space is part of `producer`.
public final class LlamaEmbedder: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable { case load(String), engine(String), invalidVector(Int) }

    public struct Configuration: Sendable, Hashable {
        /// Output dimensions (≤ the model's 1024; MRL truncation before normalization).
        public var dimensions = 1024
        /// Longest input in tokens; longer documents are rejected by `embed` callers' chunking (counted, never silently cut).
        public var maxInputTokens = 512
        /// Tokens decoded per batch (several sequences packed together).
        public var batchTokens = 4096
        /// Sequences packed in one batch at most.
        public var maxSequences = 32
        public var queryTask = "Given a question about past work meetings, retrieve transcript passages where the answer was discussed"
        public init() {}
    }

    public static let runtime = "llama.cpp-b11669"
    public let configuration: Configuration
    public let producer: EncoderProducer
    public let loadSeconds: Double
    public let modelDimensions: Int
    private let lock = NSLock()
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let endOfText: llama_token
    /// Inputs that hit `maxInputTokens` and were cut (diagnostic; chunking should keep this at 0).
    public private(set) var truncatedInputs = 0

    public init(gguf: URL, manifestID: ModelManifestID, revision: String, weightsSHA256: String, quantization: String,
                configuration: Configuration = Configuration(), chunking: String = ChunkingVersion.current) throws {
        self.configuration = configuration
        guard FileManager.default.fileExists(atPath: gguf.path) else { throw Error.load("missing \(gguf.lastPathComponent)") }
        llama_backend_init()
        let t0 = ContinuousClock.now
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let m = llama_model_load_from_file(gguf.path, mp) else { throw Error.load("load failed") }
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.pooling_type = LLAMA_POOLING_TYPE_LAST
        cp.n_ctx = UInt32(configuration.batchTokens)
        cp.n_batch = UInt32(configuration.batchTokens)
        // Pooled embeddings need each sequence inside one micro-batch.
        cp.n_ubatch = UInt32(configuration.batchTokens)
        cp.n_seq_max = UInt32(configuration.maxSequences)
        cp.kv_unified = true
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads; cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Error.load("context init failed") }
        guard let v = llama_model_get_vocab(m) else { llama_free(c); llama_model_free(m); throw Error.load("no vocab") }
        model = m; ctx = c; vocab = v
        modelDimensions = Int(llama_model_n_embd(m))
        guard configuration.dimensions > 0, configuration.dimensions <= modelDimensions else {
            llama_free(c); llama_model_free(m); throw Error.load("dimensions \(configuration.dimensions) > \(modelDimensions)")
        }
        let eot = Self.tokenize(v, "<|endoftext|>", special: true)
        guard eot.count == 1 else { llama_free(c); llama_model_free(m); throw Error.load("no <|endoftext|> token") }
        endOfText = eot[0]
        producer = EncoderProducer(family: "qwen3-embedding-0.6b", manifestID: manifestID.rawValue, revision: revision,
                                   weightsSHA256: weightsSHA256, quantization: quantization, dimensions: configuration.dimensions,
                                   pooling: "last-token+endoftext", normalization: "l2-after-mrl-truncation",
                                   queryInstruction: "Instruct: \(configuration.queryTask)\nQuery:", documentPrefix: "",
                                   chunking: chunking, runtime: Self.runtime)
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    static func tokenize(_ vocab: OpaquePointer, _ text: String, special: Bool) -> [llama_token] {
        let n = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(n) + 16)
        var got = llama_tokenize(vocab, text, n, &tokens, Int32(tokens.count), false, special)
        if got < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-got))
            got = llama_tokenize(vocab, text, n, &tokens, Int32(tokens.count), false, special)
        }
        return Array(tokens.prefix(Int(max(0, got))))
    }

    /// Encoder tokens of a document (what chunking budgets against), without the end token.
    public func countTokens(_ text: String) -> Int { lock.withLock { Self.tokenize(vocab, text, special: false).count } }

    public func queryText(_ q: String) -> String { "Instruct: \(configuration.queryTask)\nQuery:\(q)" }

    /// Vectors for `texts`, in order. `query`: apply the query instruction. Throws if cancelled between batches.
    public func embed(_ texts: [String], query: Bool, cancellation: CancellationToken = CancellationToken()) throws -> [[Float]] {
        try lock.withLock {
            let inputs = texts.map { t -> [llama_token] in
                // User text never parses as special tokens; only the end token is added.
                var toks = Self.tokenize(vocab, query ? queryText(t) : t, special: false)
                if toks.count > configuration.maxInputTokens - 1 { toks = Array(toks.prefix(configuration.maxInputTokens - 1)); truncatedInputs += 1 }
                return toks + [endOfText]
            }
            var out = [[Float]](repeating: [], count: texts.count)
            var i = 0
            var batch = llama_batch_init(Int32(configuration.batchTokens), 0, 1)
            defer { llama_batch_free(batch) }
            while i < inputs.count {
                if cancellation.isCancelled { throw CancellationError() }
                var members: [Int] = []
                var used = 0
                while i < inputs.count, members.count < configuration.maxSequences, used + inputs[i].count <= configuration.batchTokens {
                    members.append(i); used += inputs[i].count; i += 1
                }
                guard !members.isEmpty else { throw Error.engine("input longer than batch") }
                batch.n_tokens = 0
                for (seq, idx) in members.enumerated() {
                    for (pos, tok) in inputs[idx].enumerated() {
                        let k = Int(batch.n_tokens)
                        batch.token[k] = tok
                        batch.pos[k] = llama_pos(pos)
                        batch.n_seq_id[k] = 1
                        batch.seq_id[k]![0] = llama_seq_id(seq)
                        batch.logits[k] = pos == inputs[idx].count - 1 ? 1 : 0
                        batch.n_tokens += 1
                    }
                }
                llama_memory_clear(llama_get_memory(ctx), true)
                let rc = llama_decode(ctx, batch)
                guard rc == 0 else { throw Error.engine("decode \(rc)") }
                for (seq, idx) in members.enumerated() {
                    guard let p = llama_get_embeddings_seq(ctx, llama_seq_id(seq)) else { throw Error.engine("no pooled embedding") }
                    var v = Array(UnsafeBufferPointer(start: p, count: configuration.dimensions))
                    var norm: Float = 0
                    vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
                    norm = norm.squareRoot()
                    guard norm.isFinite, norm > 0 else { throw Error.invalidVector(idx) }
                    var inv = 1 / norm
                    vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
                    guard VectorCheck.isValid(v, dimensions: configuration.dimensions) else { throw Error.invalidVector(idx) }
                    out[idx] = v
                }
            }
            return out
        }
    }
}
