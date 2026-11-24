import Darwin
import Foundation
import llama

// T18: where can notes generation get faster on this Mac? Measures prefill and greedy decode throughput of the notes
// model for 1…N independent sequences decoded together, flash attention on/off and f16 vs q8_0 KV cache.
//
//   amaranth-bench llm-probe <model.gguf> <text-file> [--prompt 5000] [--gen 128] [--seqs 1,2,4] [--configs f16,q8,nofa]
enum LlmProbe {
    static func secs(_ t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func run(gguf: URL, text: URL, promptTokens: Int, genTokens: Int, seqCounts: [Int], configs: [String]) throws {
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(gguf.path, mp), let vocab = llama_model_get_vocab(model) else { fatalError("load") }
        let source = try String(contentsOf: text, encoding: .utf8)
        var all = [llama_token](repeating: 0, count: source.utf8.count + 16)
        let n = llama_tokenize(vocab, source, Int32(source.utf8.count), &all, Int32(all.count), false, true)
        all = Array(all.prefix(Int(n)))
        precondition(all.count > promptTokens * (seqCounts.max() ?? 1), "text too short")
        print("tokens available \(all.count); prompt \(promptTokens), generate \(genTokens)")
        for config in configs {
            for seqs in seqCounts {
                var cp = llama_context_default_params()
                cp.n_ctx = UInt32(seqs * (promptTokens + genTokens + 64))
                cp.n_batch = 2048
                cp.n_ubatch = UInt32(ProcessInfo.processInfo.environment["PROBE_UBATCH"].flatMap(Int.init) ?? 512)
                cp.n_seq_max = UInt32(seqs)
                cp.kv_unified = config.hasSuffix("uni")
                cp.flash_attn_type = config == "nofa" ? LLAMA_FLASH_ATTN_TYPE_DISABLED : LLAMA_FLASH_ATTN_TYPE_ENABLED
                if config.hasPrefix("q8") { cp.type_k = GGML_TYPE_Q8_0; cp.type_v = GGML_TYPE_Q8_0 }
                let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                cp.n_threads = threads; cp.n_threads_batch = threads
                guard let ctx = llama_init_from_model(model, cp) else { print("\(config) seqs=\(seqs): context init failed"); continue }
                defer { llama_free(ctx) }
                let nVocab = Int(llama_vocab_n_tokens(vocab))
                // Prefill each sequence with a different slice of the text.
                let t0 = ContinuousClock.now
                var batch = llama_batch_init(2048, 0, 1)
                defer { llama_batch_free(batch) }
                var lastLogit = [Int32](repeating: 0, count: seqs)
                for s in 0..<seqs {
                    let prompt = Array(all[(s * promptTokens)..<((s + 1) * promptTokens)])
                    var off = 0
                    while off < prompt.count {
                        let m = min(2048, prompt.count - off)
                        batch.n_tokens = Int32(m)
                        for i in 0..<m {
                            batch.token[i] = prompt[off + i]; batch.pos[i] = llama_pos(off + i)
                            batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = llama_seq_id(s); batch.logits[i] = 0
                        }
                        batch.logits[m - 1] = 1
                        guard llama_decode(ctx, batch) == 0 else { fatalError("prefill") }
                        off += m
                    }
                    lastLogit[s] = -1
                }
                let prefill = secs(t0)
                // Greedy decode: all sequences advance one token per llama_decode.
                var next = [llama_token](repeating: 0, count: seqs)
                for s in 0..<seqs {
                    // logits for each sequence's last prompt token were only kept for the final prefill batch; re-seed
                    // with a deterministic token so decode cost is what we measure.
                    next[s] = all[(s + 1) * promptTokens]
                }
                let t1 = ContinuousClock.now
                for g in 0..<genTokens {
                    batch.n_tokens = Int32(seqs)
                    for s in 0..<seqs {
                        batch.token[s] = next[s]; batch.pos[s] = llama_pos(promptTokens + g)
                        batch.n_seq_id[s] = 1; batch.seq_id[s]![0] = llama_seq_id(s); batch.logits[s] = 1
                    }
                    guard llama_decode(ctx, batch) == 0 else { fatalError("decode") }
                    for s in 0..<seqs {
                        let l = llama_get_logits_ith(ctx, Int32(s))!
                        var best = 0
                        for i in 1..<nVocab where l[i] > l[best] { best = i }
                        next[s] = llama_token(best)
                    }
                }
                let decode = secs(t1)
                if seqs == 1 {
                    // Cost of one llama_decode that scores k tokens of one sequence (speculative verification).
                    var line = "      verify k tokens in one call (ms):"
                    for k in [1, 2, 4, 8, 16] {
                        let reps = 16
                        let t2 = ContinuousClock.now
                        for r in 0..<reps {
                            let base = promptTokens + genTokens
                            _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, llama_pos(base), -1)
                            batch.n_tokens = Int32(k)
                            for i in 0..<k {
                                batch.token[i] = all[r * 31 + i]; batch.pos[i] = llama_pos(base + i)
                                batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = 0; batch.logits[i] = 1
                            }
                            guard llama_decode(ctx, batch) == 0 else { fatalError("verify") }
                            _ = llama_get_logits_ith(ctx, Int32(k - 1))
                        }
                        line += String(format: " k=%d %.1f", k, secs(t2) / Double(reps) * 1000)
                    }
                    print(line)
                }
                let footprint = AsrConcurrency.footprintMiB()
                print(String(format: "%-5@ seqs=%d  prefill %6.0f tok/s  decode %5.1f tok/s per seq, %6.1f tok/s total (%.1f ms/step)  footprint %.0f MiB",
                             config as NSString, seqs, Double(seqs * promptTokens) / prefill, Double(genTokens) / decode,
                             Double(seqs * genTokens) / decode, decode / Double(genTokens) * 1000, footprint))
            }
        }
        llama_model_free(model)
    }
}
