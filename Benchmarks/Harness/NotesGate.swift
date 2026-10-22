import Domain
import Foundation
import Notes

// T18: the perf-suite notes checks (valid evidence, planted coverage, injection, uncertain share) run in-process on the
// notes fixtures with any GGUF model and engine configuration. Used to measure candidate models (Qwen3-1.7B) that are not
// in the model pack; the app path stays the reference for anything shipped.
//
//   amaranth-bench notes-gate <model.gguf> <results-dir> [--non-thinking] [--parallel 16] [--kv 24576] [--only id,id]
enum NotesGate {
    static func run(gguf: URL, results: URL, configuration: LlamaRunner.Configuration, nonThinking: Bool, only: Set<String>?) throws {
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let runner = try LlamaRunner(gguf: gguf, manifestID: ModelManifestID(gguf.deletingPathExtension().lastPathComponent.lowercased()),
                                     revision: "local", configuration: configuration,
                                     nonThinkingPrefix: nonThinking ? "<think>\n\n</think>\n\n" : "")
        var totals = (items: 0, valid: 0, uncertain: 0, planted: 0, plantedExpected: 0, injections: 0, injectionsPassed: 0, seconds: 0.0)
        var lines: [String] = []
        for si in try PerfSuite.notesItems() where only?.contains(si.item.id) ?? true {
            let tr = try ContractCoding.decode(TranscriptRevision.self, from: Data(contentsOf: URL(filePath: si.item.transcript!)))
            let work = results.appending(path: "work/\(si.item.id)")
            let t0 = ContinuousClock.now
            let rev = try NotesPipeline(generator: runner, workDirectory: work)
                .run(meetingID: tr.meetingID, transcript: tr, editSequence: 0, scratchpad: nil, cancellation: CancellationToken())
            let seconds = LlmProbe.secs(t0)
            try ContractCoding.encode(rev).write(to: results.appending(path: "\(si.item.id)-summary.json"))
            let m = PerfSuite.notesMetrics(rev, transcript: tr, si: si)
            totals.items += m.items; totals.valid += m.itemsWithValidEvidence; totals.uncertain += m.uncertain; totals.seconds += seconds
            if let f = m.plantedFound, let e = m.plantedExpected { totals.planted += f; totals.plantedExpected += e }
            if let p = m.injectionPassed { totals.injections += 1; if p { totals.injectionsPassed += 1 } }
            let line = String(format: "%-22@ %6.1f s  items %3d  valid %3d  uncertain %3d%@%@", si.item.id as NSString, seconds, m.items,
                              m.itemsWithValidEvidence, m.uncertain,
                              m.plantedFound.map { " planted \($0)/\(m.plantedExpected ?? 0)" } ?? "",
                              m.injectionPassed.map { $0 ? " injection pass" : " injection FAIL" } ?? "")
            print(line); lines.append(line)
        }
        let summary = String(format: "TOTAL %.1f s  evidence valid %d/%d  planted %d/%d  injection %d/%d  uncertain %d/%d (%.1f%%)", totals.seconds,
                             totals.valid, totals.items, totals.planted, totals.plantedExpected, totals.injectionsPassed, totals.injections,
                             totals.uncertain, totals.items, Double(totals.uncertain) / Double(max(1, totals.items)) * 100)
        print(summary); lines.append(summary)
        try (lines.joined(separator: "\n") + "\n").write(to: results.appending(path: "notes-gate.txt"), atomically: true, encoding: .utf8)
    }
}
