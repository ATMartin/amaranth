import Domain
import Foundation
import Notes

// T110: embedding runtime probe. `amaranth-bench embed-probe <model.gguf> [--dims N] [--docs N]`
// Load time, footprint, sanity (related > unrelated), document throughput at several batch sizes, query latency.
enum EmbedProbe {
    static func run(gguf: URL, dims: Int, docs: Int) throws {
        let before = footprintMB()
        var cfg = LlamaEmbedder.Configuration(); cfg.dimensions = dims
        let e = try LlamaEmbedder(gguf: gguf, manifestID: ModelManifestID("qwen3-embedding-0.6b-q8_0"), revision: "local",
                                  weightsSHA256: "probe", quantization: "q8_0", configuration: cfg)
        print(String(format: "[embed] load %.2f s, footprint +%.0f MB (model dims %d, using %d), producer %@", e.loadSeconds, footprintMB() - before,
                     e.modelDimensions, dims, e.producer.id))
        let q = try e.embed(["Who is moving into management?"], query: true)[0]
        let d = try e.embed(["Speaker 2: Honestly I'd like to start leading a team next year, maybe take on people management.",
                             "Speaker 1: The kitchen renovation quote came in at twelve thousand dollars.",
                             "Speaker 1: Who is moving into management?"], query: false)
        func cos(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        print(String(format: "[embed] sanity: related %.3f unrelated %.3f literal-dup %.3f", cos(q, d[0]), cos(q, d[1]), cos(q, d[2])))
        let line = "Speaker 2: Yeah so the Kestrel migration needs two more people once Northgate wraps, maybe Dana could pick that up in December."
        let doc = Array(repeating: line, count: 10).joined(separator: "\n")   // ~300 tokens
        print("[embed] doc tokens:", e.countTokens(doc))
        let corpus = (0..<docs).map { "\($0) " + doc }
        let t0 = ContinuousClock.now
        _ = try e.embed(corpus, query: false)
        let s = Perf.seconds(since: t0)
        print(String(format: "[embed] %d docs of ~%d tokens: %.2f s → %.1f docs/s, %.0f tokens/s; footprint %.0f MB", docs, e.countTokens(doc), s,
                     Double(docs) / s, Double(docs * e.countTokens(doc)) / s, footprintMB()))
        var lat: [Double] = []
        for i in 0..<20 { let t = ContinuousClock.now; _ = try e.embed(["what did we decide about item \(i)?"], query: true); lat.append(Perf.seconds(since: t)) }
        lat.sort()
        print(String(format: "[embed] query latency p50 %.1f ms p95 %.1f ms max %.1f ms", lat[10] * 1000, lat[18] * 1000, lat[19] * 1000))
    }
}
