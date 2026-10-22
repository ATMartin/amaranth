import Foundation
import llama

// T18: would a small draft model speed up notes generation? Teacher-forces each `notes-trace` call (prompt + the main
// model's real output) through the draft model and counts how often the draft's greedy token equals the main model's
// next token (per-token acceptance α). With draft length k, a speculative step yields (1 − α^(k+1)) / (1 − α) tokens.
// Grammar constraints are ignored (the draft would also be constrained, so this slightly underestimates α).
//
//   amaranth-bench draft-sim <draft.gguf> <trace.jsonl> [--non-thinking]
enum DraftSim {
    static func run(gguf: URL, trace: URL, nonThinking: Bool) throws {
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(gguf.path, mp), let vocab = llama_model_get_vocab(model) else { fatalError("load") }
        defer { llama_model_free(model) }
        var cp = llama_context_default_params()
        cp.n_ctx = 8192; cp.n_batch = 2048; cp.n_ubatch = 512
        guard let ctx = llama_init_from_model(model, cp) else { fatalError("ctx") }
        defer { llama_free(ctx) }
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        func tok(_ s: String) -> [llama_token] {
            var t = [llama_token](repeating: 0, count: s.utf8.count + 16)
            let n = llama_tokenize(vocab, s, Int32(s.utf8.count), &t, Int32(t.count), false, true)
            return Array(t.prefix(Int(max(0, n))))
        }
        var batch = llama_batch_init(2048, 0, 1)
        defer { llama_batch_free(batch) }
        var byKind: [String: (tokens: Int, hits: Int)] = [:]
        var draftSeconds = 0.0, draftTokens = 0
        for line in try String(contentsOf: trace, encoding: .utf8).split(separator: "\n") {
            let call = try JSONDecoder().decode(NotesTrace.Call.self, from: Data(line.utf8))
            let kind = call.prompt.contains("You extract meeting notes") ? "extract" : call.prompt.contains("You check one proposed") ? "verify" : "overview"
            // The trace's prompts carry the main model's template; the draft shares it (same Qwen3 chat format).
            var prompt = call.prompt
            if nonThinking && !prompt.hasSuffix("</think>\n\n") { prompt += "<think>\n\n</think>\n\n" }
            let p = tok(prompt), o = tok(call.text)
            let all = p + o
            guard all.count < 8192 else { continue }
            llama_memory_clear(llama_get_memory(ctx), true)
            var hits = 0
            var off = 0
            let t0 = ContinuousClock.now
            while off < all.count {
                let n = min(2048, all.count - off)
                batch.n_tokens = Int32(n)
                for i in 0..<n {
                    let pos = off + i
                    batch.token[i] = all[pos]; batch.pos[i] = llama_pos(pos); batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = 0
                    // Logits where the next token is an output token.
                    batch.logits[i] = (pos >= p.count - 1 && pos < all.count - 1) ? 1 : 0
                }
                guard llama_decode(ctx, batch) == 0 else { fatalError("decode") }
                for i in 0..<n where batch.logits[i] != 0 {
                    let l = llama_get_logits_ith(ctx, Int32(i))!
                    var best = 0
                    for v in 1..<nVocab where l[v] > l[best] { best = v }
                    if llama_token(best) == all[off + i + 1] { hits += 1 }
                }
                off += n
            }
            draftSeconds += LlmProbe.secs(t0); draftTokens += all.count
            var k = byKind[kind] ?? (0, 0)
            k.tokens += o.count; k.hits += hits
            byKind[kind] = k
        }
        for (kind, k) in byKind.sorted(by: { $0.key < $1.key }) {
            let a = Double(k.hits) / Double(max(1, k.tokens))
            let perStep = (1...8).map { kk in (1 - pow(a, Double(kk + 1))) / (1 - a) }
            print(String(format: "%-8@ tokens %6d  acceptance α %.3f  tokens/step k=2 %.2f k=4 %.2f k=8 %.2f", kind as NSString, k.tokens, a,
                         perStep[1], perStep[3], perStep[7]))
        }
        print(String(format: "draft prefill throughput %.0f tok/s", Double(draftTokens) / draftSeconds))
    }
}
