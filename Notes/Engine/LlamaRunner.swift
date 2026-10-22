public import Foundation
public import Domain
import llama

/// llama.cpp (b11669, Metal) runner for the notes model, loaded from a verified local GGUF. The chat template is the
/// pinned `chatml-manual-v1` identity rather than the GGUF-embedded template (models/candidates.md §2).
public final class LlamaRunner: TextGenerator, @unchecked Sendable {
    public enum Error: Swift.Error { case load(String), engine(String) }

    public static let templateIdentity = "chatml-manual-v1"

    public let identity: ProducerInfo
    public let contextTokens: Int
    public let loadSeconds: Double
    private let nonThinkingPrefix: String
    private let lock = NSLock()   // one generation at a time per context
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    /// Tokens currently held in the KV cache (prompt + generated), for prefix reuse across calls.
    private var cached: [llama_token] = []
    /// Prompt tokens served from the cache, cumulatively (diagnostics).
    public private(set) var reusedPromptTokens = 0

    /// `nonThinkingPrefix` selects non-thinking mode on hybrid models (Qwen3-1.7B); empty for instruct models.
    public init(gguf: URL, manifestID: ModelManifestID, revision: String, contextTokens: Int = 8192, nonThinkingPrefix: String = "") throws {
        self.contextTokens = contextTokens
        self.nonThinkingPrefix = nonThinkingPrefix
        identity = ProducerInfo(component: "llama.cpp-b11669/\(manifestID.rawValue)", modelManifestID: manifestID, modelVersion: revision,
                                configHash: "\(Self.templateIdentity):ctx\(contextTokens):greedy")
        guard FileManager.default.fileExists(atPath: gguf.path) else { throw Error.load("missing \(gguf.lastPathComponent)") }
        llama_backend_init()
        let t0 = ContinuousClock.now
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let m = llama_model_load_from_file(gguf.path, mp) else { throw Error.load("load failed") }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = 2048
        cp.n_ubatch = 512
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Error.load("context init failed") }
        guard let v = llama_model_get_vocab(m) else { llama_free(c); llama_model_free(m); throw Error.load("no vocab") }
        model = m; ctx = c; vocab = v
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func tokenize(_ text: String) -> [llama_token] {
        let n = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(n) + 16)
        let got = llama_tokenize(vocab, text, n, &tokens, Int32(tokens.count), false, true)
        if got < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-got))
            _ = llama_tokenize(vocab, text, n, &tokens, Int32(tokens.count), false, true)
            return tokens
        }
        return Array(tokens.prefix(Int(got)))
    }

    public func countTokens(_ text: String) -> Int { lock.withLock { tokenize(text).count } }

    public func chatPrompt(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n\(nonThinkingPrefix)"
    }

    public func generate(prompt: String, grammar: String?, maxTokens: Int, cancellation: CancellationToken) throws -> GenerationResult {
        try lock.withLock { try generateLocked(prompt: prompt, grammar: grammar, maxTokens: maxTokens, cancellation: cancellation) }
    }

    private func generateLocked(prompt: String, grammar: String?, maxTokens: Int, cancellation: CancellationToken) throws -> GenerationResult {
        try cancellation.check()
        var tokens = tokenize(prompt)
        // Reuse the KV cache for the longest shared prefix (the system prompt is identical across calls of one kind);
        // keep at least one token to decode so fresh logits exist.
        var shared = 0
        while shared < min(cached.count, tokens.count - 1), cached[shared] == tokens[shared] { shared += 1 }
        let mem = llama_get_memory(ctx)
        if shared == 0 || !llama_memory_seq_rm(mem, 0, llama_pos(shared), -1) {
            llama_memory_clear(mem, true)
            shared = 0
        }
        cached = Array(tokens.prefix(shared))
        reusedPromptTokens += shared
        guard tokens.count + maxTokens <= contextTokens else {
            throw Error.engine("prompt \(tokens.count) + output \(maxTokens) exceeds context \(contextTokens)")
        }
        var grammarSampler: UnsafeMutablePointer<llama_sampler>?
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Error.engine("grammar parse failed") }
            grammarSampler = g
        }
        defer { if let g = grammarSampler { llama_sampler_free(g) } }
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var full = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var offset = shared
        defer { if offset < tokens.count { cached = []; llama_memory_clear(llama_get_memory(ctx), true) } }   // interrupted prefill
        Perf.count("llm.calls")
        Perf.count("llm.promptTokens", tokens.count)
        Perf.count("llm.reusedPromptTokens", shared)
        let prefillStart = ContinuousClock.now
        while offset < tokens.count {
            try cancellation.check()
            let n = min(2048, tokens.count - offset)
            let rc = tokens.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress! + offset, Int32(n))) }
            guard rc == 0 else { throw Error.engine("prefill decode \(rc)") }
            cached += tokens[offset..<(offset + n)]
            offset += n
        }
        Perf.add("llm.prefill", seconds: Perf.seconds(since: prefillStart))
        let generateStart = ContinuousClock.now
        var sampleSeconds = 0.0
        defer {
            Perf.add("llm.generate", seconds: Perf.seconds(since: generateStart))
            Perf.add("llm.generate.sampling", seconds: sampleSeconds)
        }
        var out = ""
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        var hitLimit = true
        while generated < maxTokens {
            if cancellation.isCancelled { cached = []; llama_memory_clear(llama_get_memory(ctx), true); throw CancellationError() }
            guard let logits = llama_get_logits_ith(ctx, -1) else { throw Error.engine("no logits") }
            let sampleStart = ContinuousClock.now
            var best = 0
            for i in 1..<nVocab where logits[i] > logits[best] { best = i }
            var tok = llama_token(best)
            // llama.cpp's grammar fast path: check only the greedy token; filter the full vocabulary only on rejection.
            if let g = grammarSampler {
                var one = llama_token_data(id: tok, logit: logits[best], p: 0)
                withUnsafeMutablePointer(to: &one) { ptr in
                    var arr = llama_token_data_array(data: ptr, size: 1, selected: -1, sorted: false)
                    llama_sampler_apply(g, &arr)
                }
                if one.logit == -Float.infinity {
                    for i in 0..<nVocab { full[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
                    full.withUnsafeMutableBufferPointer { buf in
                        var arr = llama_token_data_array(data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
                        llama_sampler_apply(g, &arr)
                    }
                    var b = 0
                    for i in 1..<nVocab where full[i].logit > full[b].logit { b = i }
                    tok = full[b].id
                }
                llama_sampler_accept(g, tok)
            }
            sampleSeconds += Perf.seconds(since: sampleStart)
            if llama_vocab_is_eog(vocab, tok) { hitLimit = false; break }
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if len > 0 { out += String(decoding: piece.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            generated += 1
            let rc = llama_decode(ctx, llama_batch_get_one(&tok, 1))
            guard rc == 0 else { cached = []; llama_memory_clear(llama_get_memory(ctx), true); throw Error.engine("decode \(rc)") }
            cached.append(tok)
        }
        Perf.count("llm.generatedTokens", generated)
        return GenerationResult(text: out, promptTokens: tokens.count, generatedTokens: generated, hitTokenLimit: hitLimit)
    }
}
