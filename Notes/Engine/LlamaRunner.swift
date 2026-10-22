public import Foundation
public import Domain
import Accelerate
import llama

/// llama.cpp (b11669, Metal) runner for the notes model, loaded from a verified local GGUF. The chat template is the
/// pinned `chatml-manual-v1` identity rather than the GGUF-embedded template (models/candidates.md §2).
///
/// T18: independent requests are decoded together (continuous batching). Up to `parallel` sequences share one KV cache
/// of `kvTokens` cells. Every step decodes the next token of each generating sequence plus prompt chunks of newly
/// admitted ones; a request starts as soon as a sequence and enough KV cells are free. Each new request reuses the
/// longest prompt prefix already in the cache (from any sequence, shared rather than copied), so shared system prompts
/// are prefilled once. Decoding stays greedy and grammar-constrained per sequence.
public final class LlamaRunner: TextGenerator, @unchecked Sendable {
    public enum Error: Swift.Error { case load(String), engine(String) }

    public static let templateIdentity = "chatml-manual-v1"

    public struct Configuration: Sendable, Hashable {
        /// Largest prompt + output of one request.
        public var contextTokens = 8192
        /// Sequences decoded together.
        public var parallel = 16
        /// KV cache cells shared by all sequences.
        public var kvTokens = 24_576
        public init() {}
        /// One sequence with its own 8,192-token cache: the v0 (notes-v1) engine.
        public static let sequential: Configuration = { var c = Configuration(); c.parallel = 1; c.kvTokens = c.contextTokens; return c }()
    }

    public let identity: ProducerInfo
    public let configuration: Configuration
    public var contextTokens: Int { configuration.contextTokens }
    public let loadSeconds: Double
    private let nonThinkingPrefix: String
    private let lock = NSLock()   // one batch at a time per context
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let nVocab: Int
    /// Tokens currently held in the KV cache per sequence (prompt + decoded output), for prefix reuse across calls.
    private var cached: [[llama_token]]
    /// Prompt tokens served from the cache, cumulatively (diagnostics).
    public private(set) var reusedPromptTokens = 0

    /// `nonThinkingPrefix` selects non-thinking mode on hybrid models (Qwen3-1.7B); empty for instruct models.
    public init(gguf: URL, manifestID: ModelManifestID, revision: String, configuration: Configuration = Configuration(),
                nonThinkingPrefix: String = "") throws {
        precondition(configuration.parallel >= 1 && configuration.kvTokens >= configuration.contextTokens)
        self.configuration = configuration
        self.nonThinkingPrefix = nonThinkingPrefix
        let batching = configuration.parallel == 1 ? "" : ":batch\(configuration.parallel)x\(configuration.kvTokens)"
        identity = ProducerInfo(component: "llama.cpp-b11669/\(manifestID.rawValue)", modelManifestID: manifestID, modelVersion: revision,
                                configHash: "\(Self.templateIdentity):ctx\(configuration.contextTokens):greedy\(batching)")
        guard FileManager.default.fileExists(atPath: gguf.path) else { throw Error.load("missing \(gguf.lastPathComponent)") }
        llama_backend_init()
        let t0 = ContinuousClock.now
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let m = llama_model_load_from_file(gguf.path, mp) else { throw Error.load("load failed") }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(configuration.kvTokens)
        cp.n_batch = 2048
        cp.n_ubatch = 512
        cp.n_seq_max = UInt32(configuration.parallel)
        // Unified: sequences share cells (prefix reuse without copies) and use whatever room the others leave.
        cp.kv_unified = true
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Error.load("context init failed") }
        guard let v = llama_model_get_vocab(m) else { llama_free(c); llama_model_free(m); throw Error.load("no vocab") }
        model = m; ctx = c; vocab = v
        nVocab = Int(llama_vocab_n_tokens(v))
        cached = Array(repeating: [], count: configuration.parallel)
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
        var result: GenerationResult?
        try generateBatch([GenerationRequest(prompt: prompt, grammar: grammar, maxTokens: maxTokens)], cancellation: cancellation) { result = $1 }
        return result!
    }

    public func generateBatch(_ requests: [GenerationRequest], cancellation: CancellationToken,
                              onResult: (Int, GenerationResult) throws -> Void) throws {
        try generateStream(requests, cancellation: cancellation) { try onResult($0, $1); return [] }
    }

    public func generateStream(_ requests: [GenerationRequest], cancellation: CancellationToken,
                               onResult: (Int, GenerationResult) throws -> [GenerationRequest]) throws {
        try lock.withLock { try runBatch(requests, cancellation: cancellation, onResult: onResult) }
    }

    // MARK: Continuous batching

    /// A request occupying a sequence.
    private struct Active {
        var request: Int
        var tokens: [llama_token]          // prompt
        var offset: Int                    // prompt tokens already in the cache
        var maxTokens: Int
        var grammar: UnsafeMutablePointer<llama_sampler>?
        var pending: llama_token?          // sampled, not yet decoded
        var text = ""
        var generated = 0
    }

    private func runBatch(_ initial: [GenerationRequest], cancellation: CancellationToken,
                          onResult: (Int, GenerationResult) throws -> [GenerationRequest]) throws {
        try cancellation.check()
        var requests: [GenerationRequest] = []
        var prompts: [[llama_token]] = []
        var queue: [Int] = []
        func enqueue(_ new: [GenerationRequest]) throws {
            for r in new {
                let p = tokenize(r.prompt)
                guard p.count + r.maxTokens <= contextTokens else {
                    throw Error.engine("prompt \(p.count) + output \(r.maxTokens) exceeds context \(contextTokens)")
                }
                queue.append(requests.count)
                requests.append(r); prompts.append(p)
            }
        }
        try enqueue(initial)
        let mem = llama_get_memory(ctx)
        var slots = [Active?](repeating: nil, count: configuration.parallel)
        var batch = llama_batch_init(2048, 0, 1)
        var full = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var piece = [CChar](repeating: 0, count: 256)
        var completed = false
        defer {
            llama_batch_free(batch)
            for s in slots.indices { if let g = slots[s]?.grammar { llama_sampler_free(g) } }
            // Anything interrupted leaves partial sequences: drop the whole cache rather than track them.
            if !completed { llama_memory_clear(mem, true); cached = Array(repeating: [], count: configuration.parallel) }
        }
        var prefillSeconds = 0.0, generateSeconds = 0.0, sampleSeconds = 0.0
        defer {
            Perf.add("llm.prefill", seconds: prefillSeconds)
            Perf.add("llm.generate", seconds: generateSeconds)
            Perf.add("llm.generate.sampling", seconds: sampleSeconds)
        }

        /// Cells the active sequences may still need, counting shared prefixes once per sequence (an overestimate).
        func reserved() -> Int {
            slots.indices.reduce(0) { sum, s in
                guard let a = slots[s] else { return sum }
                return sum + a.tokens.count + a.maxTokens
            }
        }
        /// Cells held by idle sequences' caches.
        func idleCells() -> Int { slots.indices.filter { slots[$0] == nil }.reduce(0) { $0 + cached[$1].count } }

        /// Starts queued requests while a sequence and enough cells are free. Requests start in order; when the next one
        /// does not fit, later ones that do fit may use the spare cells (short verifications beside long extractions).
        func admit() throws {
            while let free = slots.firstIndex(where: { $0 == nil }),
                  let q = queue.firstIndex(where: { reserved() + prompts[$0].count + requests[$0].maxTokens <= configuration.kvTokens }) {
                let next = queue[q]
                let tokens = prompts[next], r = requests[next]
                // Longest cached prefix in any sequence; keep at least one prompt token to decode so fresh logits exist.
                var best = (seq: free, length: 0)
                for s in cached.indices {
                    var n = 0
                    while n < min(cached[s].count, tokens.count - 1), cached[s][n] == tokens[n] { n += 1 }
                    if n > best.length || (n == best.length && s == free) { best = (s, n) }
                }
                // Prefer the best idle sequence itself as the target (no sharing needed).
                var target = free
                if slots[best.seq] == nil { target = best.seq }
                if best.seq == target {
                    if !llama_memory_seq_rm(mem, llama_seq_id(target), llama_pos(best.length), -1) {
                        _ = llama_memory_seq_rm(mem, llama_seq_id(target), -1, -1); best.length = 0
                    }
                } else {
                    _ = llama_memory_seq_rm(mem, llama_seq_id(target), -1, -1)
                    if best.length > 0 { llama_memory_seq_cp(mem, llama_seq_id(best.seq), llama_seq_id(target), 0, llama_pos(best.length)) }
                }
                cached[target] = Array(tokens.prefix(best.length))
                // Free idle caches (oldest content first) until the shared cache has room for everything admitted.
                for s in slots.indices where slots[s] == nil && s != target && reserved() + tokens.count + r.maxTokens + idleCells() > configuration.kvTokens {
                    _ = llama_memory_seq_rm(mem, llama_seq_id(s), -1, -1); cached[s] = []
                }
                var grammar: UnsafeMutablePointer<llama_sampler>?
                if let g = r.grammar {
                    guard let s = llama_sampler_init_grammar(vocab, g, "root") else { throw Error.engine("grammar parse failed") }
                    grammar = s
                }
                slots[target] = Active(request: next, tokens: tokens, offset: best.length, maxTokens: r.maxTokens, grammar: grammar)
                queue.remove(at: q)
                reusedPromptTokens += best.length
                Perf.count("llm.calls")
                Perf.count("llm.promptTokens", tokens.count)
                Perf.count("llm.reusedPromptTokens", best.length)
            }
        }

        func finish(_ s: Int, hitLimit: Bool) throws {
            guard let a = slots[s] else { return }
            if let g = a.grammar { llama_sampler_free(g) }
            slots[s] = nil
            Perf.count("llm.generatedTokens", a.generated)
            try enqueue(try onResult(a.request, GenerationResult(text: a.text, promptTokens: a.tokens.count, generatedTokens: a.generated,
                                                                 hitTokenLimit: hitLimit)))
        }

        try admit()
        while slots.contains(where: { $0 != nil }) {
            try cancellation.check()
            // Build one batch: each generating sequence's pending token, then prompt chunks.
            batch.n_tokens = 0
            var logitsAt: [(seq: Int, index: Int32)] = []
            func add(_ token: llama_token, seq: Int, logits: Bool) {
                let i = Int(batch.n_tokens)
                batch.token[i] = token
                batch.pos[i] = llama_pos(cached[seq].count)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = llama_seq_id(seq)
                batch.logits[i] = logits ? 1 : 0
                batch.n_tokens += 1
                cached[seq].append(token)
                if logits { logitsAt.append((seq, Int32(i))) }
            }
            for s in slots.indices { if let t = slots[s]?.pending { add(t, seq: s, logits: true); slots[s]!.pending = nil } }
            var prefilling = false
            for s in slots.indices where slots[s].map({ $0.offset < $0.tokens.count }) ?? false && batch.n_tokens < 2048 {
                var a = slots[s]!
                let n = min(a.tokens.count - a.offset, 2048 - Int(batch.n_tokens))
                for k in 0..<n { add(a.tokens[a.offset + k], seq: s, logits: a.offset + k == a.tokens.count - 1) }
                a.offset += n
                slots[s] = a
                prefilling = true
            }
            let stepStart = ContinuousClock.now
            let rc = llama_decode(ctx, batch)
            guard rc == 0 else { throw Error.engine("decode \(rc)") }
            // Sample every sequence whose last prompt token or pending token was just decoded.
            for (s, index) in logitsAt {
                guard var a = slots[s], let logits = llama_get_logits_ith(ctx, index) else { throw Error.engine("no logits") }
                let sampleStart = ContinuousClock.now
                var maxValue: Float = 0
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(logits, 1, &maxValue, &maxIndex, vDSP_Length(nVocab))
                var tok = llama_token(maxIndex)
                // llama.cpp's grammar fast path: check only the greedy token; filter the full vocabulary only on rejection.
                if let g = a.grammar {
                    var one = llama_token_data(id: tok, logit: maxValue, p: 0)
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
                if llama_vocab_is_eog(vocab, tok) { try finish(s, hitLimit: false); continue }
                let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
                if len > 0 { a.text += String(decoding: piece.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                a.generated += 1
                a.pending = tok
                slots[s] = a
                if a.generated >= a.maxTokens { slots[s]!.pending = nil; try finish(s, hitLimit: true) }
            }
            let stepSeconds = Perf.seconds(since: stepStart)
            if prefilling { prefillSeconds += stepSeconds } else { generateSeconds += stepSeconds }
            Perf.count("llm.steps")
            try admit()
        }
        completed = true
    }
}
