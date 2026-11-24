import Foundation
import llama

// T18: how many decode steps would speculative decoding save on real notes calls? Replays a `notes-trace` JSONL: for
// each call, drafts up to K tokens by prompt lookup (the longest n-gram suffix match in prompt + output so far) and
// counts the accepted prefix against the real greedy output. Exact for greedy decoding: a step accepts the matching
// draft prefix plus one token from the main model.
//
//   amaranth-bench spec-sim <model.gguf> <trace.jsonl> [--k 8] [--ngram 3]
enum SpecSim {
    static func run(gguf: URL, trace: URL, maxDraft: Int, maxNgram: Int) throws {
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 0
        mp.vocab_only = true
        guard let model = llama_model_load_from_file(gguf.path, mp), let vocab = llama_model_get_vocab(model) else { fatalError("load") }
        defer { llama_model_free(model) }
        func tok(_ s: String) -> [llama_token] {
            var t = [llama_token](repeating: 0, count: s.utf8.count + 16)
            let n = llama_tokenize(vocab, s, Int32(s.utf8.count), &t, Int32(t.count), false, true)
            return Array(t.prefix(Int(max(0, n))))
        }
        var byKind: [String: (calls: Int, tokens: Int, steps: Int, drafted: Int)] = [:]
        for line in try String(contentsOf: trace, encoding: .utf8).split(separator: "\n") {
            let call = try JSONDecoder().decode(NotesTrace.Call.self, from: Data(line.utf8))
            let kind = call.prompt.contains("You extract meeting notes") ? "extract"
                : call.prompt.contains("You check one proposed") ? "verify" : "overview"
            let prompt = tok(call.prompt), output = tok(call.text)
            var context = prompt
            var i = 0, steps = 0, drafted = 0
            while i < output.count {
                // Draft: find the most recent earlier occurrence of the last n tokens, propose what followed it.
                var draft: [llama_token] = []
                for n in stride(from: maxNgram, through: 1, by: -1) where context.count > n {
                    let suffix = Array(context.suffix(n))
                    var j = context.count - n - 1
                    while j >= 0 {
                        if Array(context[j..<(j + n)]) == suffix {
                            draft = Array(context[(j + n)..<min(context.count, j + n + maxDraft)])
                            break
                        }
                        j -= 1
                    }
                    if !draft.isEmpty { break }
                }
                var accepted = 0
                while accepted < draft.count, i + accepted < output.count, draft[accepted] == output[i + accepted] { accepted += 1 }
                drafted += draft.count
                let advance = min(output.count - i, accepted + 1)
                context += output[i..<(i + advance)]
                i += advance
                steps += 1
            }
            var k = byKind[kind] ?? (0, 0, 0, 0)
            k.calls += 1; k.tokens += output.count; k.steps += steps; k.drafted += drafted
            byKind[kind] = k
        }
        var total = (tokens: 0, steps: 0)
        for (kind, k) in byKind.sorted(by: { $0.key < $1.key }) {
            total.tokens += k.tokens; total.steps += k.steps
            print(String(format: "%-8@ calls %3d  tokens %6d  steps %6d  tokens/step %.2f  drafted/step %.1f", kind as NSString, k.calls, k.tokens,
                         k.steps, Double(k.tokens) / Double(max(1, k.steps)), Double(k.drafted) / Double(max(1, k.steps))))
        }
        print(String(format: "all      tokens %d steps %d tokens/step %.2f (K=%d, n≤%d)", total.tokens, total.steps,
                     Double(total.tokens) / Double(max(1, total.steps)), maxDraft, maxNgram))
    }
}
