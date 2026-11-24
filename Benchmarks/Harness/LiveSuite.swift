import Foundation
import Domain

/// T20 `amaranth-bench live-suite run --app <Amaranth.app> [--seconds 300] [--tick 0.25] [--per-source yes|no]
/// [--incremental yes|no] [--only id,…] [--results dir]`: live text delay on real recordings (gate G4). Defaults are the
/// app's live text settings (T20: 0.25 s check, one request per source); v1 was `--tick 2 --per-source no`.
///
/// Excerpts of the corpus meetings recorded in Amaranth (separate mic and system tracks, consent given) are replayed in
/// real time through the app's `--self-test live-replay` (real capture path, XPC worker, incremental processing).
/// Writes `measurements.json` and `report.md`: delay median/p95 per meeting and pooled, where the time goes, and how
/// much the live words differ from each meeting's final transcript. Metrics and meeting IDs only, never text.
/// `score <results>` rewrites the report from existing outputs.
enum LiveSuite {
    static func main(_ args: [String]) async throws -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        switch args.first {
        case "run":
            guard let app = value("--app") else { print("live-suite run: --app <Amaranth.app> required"); return 2 }
            let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let results = URL(filePath: value("--results") ?? "Benchmarks/Results/\(date)-live")
            var items = try items(seconds: Double(value("--seconds") ?? "300") ?? 300)
            if let only = value("--only").map({ Set($0.split(separator: ",").map(String.init)) }) { items = items.filter { only.contains($0.id) } }
            guard !items.isEmpty else { print("live-suite: no items"); return 2 }
            let outputs = results.appending(path: "outputs")
            try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
            let spec = LiveReplay.Spec(items: items, outputDirectory: outputs.path, tickSeconds: Double(value("--tick") ?? "0.25") ?? 0.25,
                                       perSource: value("--per-source") != "no", incremental: value("--incremental") != "no")
            // The spec names private library copies and meeting IDs: it stays in the gitignored `outputs/`.
            let specURL = outputs.appending(path: "live-spec.json")
            try ContractCoding.encode(spec).write(to: specURL)
            let log = results.appending(path: "live-run.jsonl")
            let total = items.map(\.seconds).reduce(0, +)
            print(String(format: "[live] replaying %d excerpts (%.0f min, real time) through %@ (log: %@)", items.count, total / 60, app, log.path))
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/open")
            p.arguments = ["-W", "-n", app, "--args", "--self-test", "live-replay", "--live-spec", specURL.path, "--self-test-output", log.path]
            try p.run()
            p.waitUntilExit()
            return try score(results: results)
        case "score" where args.count >= 2:
            return try score(results: URL(filePath: args[1]))
        default:
            print("usage: amaranth-bench live-suite run|score … (see Benchmarks/Harness/LiveSuite.swift)")
            return 2
        }
    }

    /// One excerpt per consented Amaranth-recorded corpus meeting with separate tracks: `seconds` long, starting 5 min
    /// in when the meeting is long enough (past greetings), else centred; short meetings are used whole.
    static func items(seconds: Double) throws -> [LiveReplay.Item] {
        let ownLibrary = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Amaranth")
        var copies: [URL: URL] = [:]
        var out: [LiveReplay.Item] = []
        var fromOtherMac = 0
        for row in try PerfSuite.manifest() where row.fields["consent"]?.lowercased() == "yes" && row.fields["tracks"] == "separate" {
            let library = row.fields["library"].flatMap { $0.isEmpty ? nil : $0 }
                .map { $0.hasPrefix("/") ? URL(filePath: $0) : PerfSuite.corpus.appending(path: $0) } ?? ownLibrary
            if copies[library] == nil { copies[library] = try PerfSuite.copyLibrary(library, index: copies.count) }
            guard let copy = copies[library], let meeting = try PerfSuite.meetingID(title: row.id, library: copy) else {
                print("[live] skipping \(row.id): not a meeting in \(library.path)"); continue
            }
            try FileManager.default.copyItem(at: library.appending(path: "meetings/\(meeting)"), to: copy.appending(path: "meetings/\(meeting)"))
            let duration = Double(row.fields["duration_s"] ?? "") ?? 0
            let length = min(seconds, duration)
            let start = duration >= length + 300 + 30 ? 300 : max(0, (duration - length) / 2)
            // Meetings from another Mac's library are titled with colleagues' names: their IDs are numbered instead.
            let isOther = row.fields["library"].map { !$0.isEmpty } ?? false
            if isOther { fromOtherMac += 1 }
            out.append(LiveReplay.Item(id: isOther ? "corpus-work-mac-\(fromOtherMac)" : PerfSuite.slug(row.id), library: copy.path, meetingID: meeting, start: start, seconds: length))
        }
        return out
    }

    struct Measurements: Codable {
        var created: Date
        var tickSeconds: Double?
        var perSource: Bool?
        var incremental: Bool?
        var items: [LiveReplay.Result]
        var pooledSamples: Int
        var pooledMedianSeconds: Double?
        var pooledP95Seconds: Double?
        var g4Met: Bool
    }

    static func score(results: URL) throws -> Int32 {
        let outputs = results.appending(path: "outputs")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: outputs, includingPropertiesForKeys: nil)) ?? []
        let items = dirs.compactMap { try? ContractCoding.decode(LiveReplay.Result.self, from: Data(contentsOf: $0.appending(path: "result.json"))) }
            .sorted { $0.id < $1.id }
        guard !items.isEmpty else { print("[live] no results in \(outputs.path)"); return 1 }
        let pooled = items.flatMap(\.latencies)
        let median = LivePercentile.of(pooled, 0.5), p95 = LivePercentile.of(pooled, 0.95)
        let met = items.allSatisfy(\.completed) && (median ?? .infinity) <= 2 && (p95 ?? .infinity) <= 4
        let m = Measurements(created: Date(), tickSeconds: items.first?.tickSeconds, perSource: items.first?.perSource, incremental: items.first?.incremental,
                             items: items, pooledSamples: pooled.count, pooledMedianSeconds: median, pooledP95Seconds: p95, g4Met: met)
        try JSONEncoder.pretty.encode(m).write(to: results.appending(path: "measurements.json"))
        func f(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "–" }
        func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
        var md = ["# Live text delay on real recordings (T20, gate G4)", "",
                  "Settings: check every \(f(m.tickSeconds, 2)) s, per-source requests \(m.perSource == true ? "yes" : "no"), incremental processing \(m.incremental == true ? "on" : "off"). Real-time replay of corpus excerpts through the real capture path and XPC worker.", "",
                  "**Pooled: median \(f(median)) s, p95 \(f(p95)) s over \(pooled.count) words. G4 (median ≤ 2 s, p95 ≤ 4 s): \(met ? "met" : "NOT met").**", "",
                  "| Meeting | Audio (s) | Words | Median (s) | p95 (s) | Segment wait (median) | Send wait (median / p95) | Worker (median / p95) | Mic vs final | System vs final | Loss / overruns | App / worker peak (MiB) |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in items {
            let mic = r.sources.first { $0.source == SourceKind.microphone.rawValue }, sys = r.sources.first { $0.source == SourceKind.systemOutput.rawValue }
            md.append("| \(r.id)\(r.completed ? "" : " (failed: \(r.failure ?? "?"))") | \(f(r.audioSeconds, 0)) | \(r.latencies.count) | \(f(r.medianSeconds)) | \(f(r.p95Seconds)) | \(f(r.medianUnsaved)) | \(f(r.medianWaiting)) / \(f(r.p95Waiting)) | \(f(r.medianWorker)) / \(f(r.p95Worker)) | \(pct(mic?.disagreementWithFinal)) | \(pct(sys?.disagreementWithFinal)) | \(r.missingAudioEvents) / \(r.ringOverruns) | \(f(r.appPeakMiB, 0)) / \(f(r.workerPeakMiB, 0)) |")
        }
        md += ["", "- *Segment wait*: from the end of a word until the end of the 2 s capture segment holding it (session time). *Send wait*: from then until live text sent it to the worker (includes saving the segment). *Worker*: the request's round trip.",
               "- *vs final*: word error rate of the live words against the meeting's final transcript over the excerpt. This is agreement, not accuracy: the final transcript is not a human reference."]
        try md.joined(separator: "\n").appending("\n").write(to: results.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print("[live] pooled median \(f(median)) s, p95 \(f(p95)) s over \(pooled.count) words; G4 \(met ? "met" : "NOT met") → \(results.appending(path: "report.md").path)")
        return met ? 0 : 1
    }
}

enum LivePercentile {
    /// Nearest-rank percentile, as the app's `LiveLatencyLog.percentile`.
    static func of(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}
