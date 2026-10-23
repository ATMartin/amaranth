import Foundation
import Domain
import Scoring

/// `report.md` for `perf-suite`: metrics and item IDs only, never transcript or notes text (plan §10).
enum PerfReport {
    typealias M = PerfSuite.Measurements

    static func f(_ x: Double?, _ digits: Int = 1) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "–" }
    static func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

    static func markdown(_ m: M) -> String {
        var md: [String] = []
        let builds = Set(m.items.flatMap { $0.stages.compactMap(\.build) }).sorted().joined(separator: ", ")
        let qos = Set(m.items.flatMap { $0.stages.compactMap(\.qos) }).sorted().joined(separator: ", ")
        md += ["# Perf suite report", "",
               "Generated \(ISO8601DateFormatter().string(from: m.created)) · commit `\(m.host["git"] ?? "?")` · \(m.host["cpu"] ?? "") · macOS \(m.host["os"] ?? "")",
               "· worker build **\(builds.isEmpty ? "?" : builds)** · worker QoS \(qos.isEmpty ? "?" : qos) · \(m.host["power"] ?? "")", "",
               "Contains metrics and item IDs only (no transcript or notes text).", ""]
        md += gates(m)
        md += itemTable(m)
        md += breakdown(m)
        md += quality(m)
        if let c = m.comparison { md += comparison(c) }
        return md.joined(separator: "\n") + "\n"
    }

    /// Runs that replay a meeting as a recording in progress (T19).
    static func isIncremental(_ i: PerfSuite.ItemMetrics) -> Bool { i.run == "incremental" || i.run.hasPrefix("b2b") }

    /// G1–G7 against docs/milestone-e-performance-plan.md targets.
    static func gates(_ m: M) -> [String] {
        let corpus = m.items.filter { ($0.suite == "corpus" || $0.set == "timing") && $0.completed }
        // G1–G3 are stated for a 60-minute meeting: use meetings of ≥ 50 min, scaled to 60 min (short meetings are
        // dominated by fixed per-job cost and would overstate a per-hour rate).
        let long = corpus.filter { $0.audioSeconds >= 3000 && !isIncremental($0) }
        func scaled(_ xs: [(Double?, Double)]) -> Double? { xs.compactMap { s, a in s.map { $0 / a * 3600 } }.max() }
        let g1 = scaled(long.map { ($0.stopToTranscriptSeconds, $0.audioSeconds) })
        let g2 = scaled(long.map { ($0.stopToNotesSeconds, $0.audioSeconds) })
        let longT = long.map { "\($0.id)/\($0.run) \(f($0.stopToTranscriptSeconds, 0)) s for \(f($0.audioSeconds / 60, 0)) min" }.joined(separator: "; ")
        let longN = long.map { "\($0.id)/\($0.run) \(f($0.stopToNotesSeconds, 0)) s" }.joined(separator: "; ")
        // T19: with processing during the recording, the target is absolute (≤ 20 s for 60- and 120-minute meetings).
        let inc = corpus.filter { $0.run == "incremental" && $0.audioSeconds >= 3000 }
        let g1i = inc.compactMap(\.stopToTranscriptSeconds).max()
        let incT = inc.map { "\($0.id) \(f($0.stopToTranscriptSeconds, 0)) s for \(f($0.audioSeconds / 60, 0)) min" }.joined(separator: "; ")
        let b2b = m.items.filter { $0.run == "b2b-1" }
        let g7 = b2b.isEmpty ? nil : b2b.allSatisfy { $0.completed && $0.transcriptReadyBeforeNextStop == true && $0.transcriptJobsLeftAtNextStop == 0 }
        let b2bT = b2b.map { "\($0.id): ready \(f($0.stopToTranscriptSeconds, 0)) s after Stop, next Stop at \(f($0.nextStopSeconds, 0)) s, \($0.transcriptJobsLeftAtNextStop.map(String.init) ?? "?") stages left" }.joined(separator: "; ")
        func status(_ v: Double?, _ target: Double) -> String { v.map { $0 <= target ? "met" : "**not met**" } ?? "–" }
        var g5 = "not compared (run with `--compare <baseline>`)"
        if let c = m.comparison { g5 = c.breaches.isEmpty ? "**pass** (\(c.flagged.count) corpus flags for review)" : "**FAIL** (\(c.breaches.count) breaches)" }
        return ["## Gates (M2 Max measured)", "",
                "| # | Gate | Target (batch / incremental) | Measured | Status |", "|---|---|---|---|---|",
                "| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | batch: \(f(g1, 0)) s per 60 min (worst ≥ 50-min meeting): \(longT.isEmpty ? "no meeting ≥ 50 min" : longT). While recording: \(incT.isEmpty ? "not run" : incT) | \(status(g1, 60)) (batch); \(status(g1i, 20)) (while recording) |",
                "| G2 | Stop → notes, 60 min | ≤ 300 s | \(f(g2, 0)) s per 60 min: \(longN.isEmpty ? "no meeting ≥ 50 min" : longN) | \(status(g2, 300)) |",
                "| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 batch | \(status(g1, 60)) |",
                "| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |",
                "| G5 | Quality guard vs v0 | no breach | \(g5) | |",
                "| G6 | Capture safety while processing during a call | zero loss | measured by `--self-test live-load` (processing/0003) | – |",
                "| G7 | Back-to-back meetings | meeting 1 ready while 2 records | \(b2bT.isEmpty ? "not run" : b2bT) | \(g7.map { $0 ? "met" : "**not met**" } ?? "–") |", ""]
            + incrementalTable(m)
    }

    /// T19: what processing while recording did, and whether the final transcript equals the item's batch run.
    static func incrementalTable(_ m: M) -> [String] {
        let runs = m.items.filter(isIncremental)
        guard !runs.isEmpty else { return [] }
        var md = ["## Processing while recording (T19)", "",
                  "Replayed at \(f(runs.first?.incremental?.liveSpeed, 0))× realtime. *Final at Stop*: end of final-quality text per source when recording stopped. *Reused*: windows the transcription stage took from incremental results (identical window and audio).", "",
                  "| Item | Run | Audio min | Stop→transcript | transcribe exec | diarize exec | Requests (busy, failed, paused) | Windows decoded | Final at Stop (s) | Reused windows | Identical to batch run |",
                  "|---|---|---|---|---|---|---|---|---|---|---|"]
        for i in runs {
            let inc = i.incremental
            let fin = inc?.finalizedUntil.sorted { $0.key < $1.key }.map { "\($0.key) \(f($0.value, 0))" }.joined(separator: ", ") ?? "–"
            md.append("| \(i.id) | \(i.run) | \(f(i.audioSeconds / 60)) | \(f(i.stopToTranscriptSeconds)) | \(stage(i, "transcribe").map { f($0.executeSeconds) } ?? "–") | \(stage(i, "diarize").map { f($0.executeSeconds) } ?? "–") | \(inc.map { "\($0.requests) (\($0.busyReplies), \($0.failures), \($0.pausedTicks))" } ?? "–") | \(inc.map { "\($0.decodedWindows)/\($0.plannedWindows)" } ?? "–") | \(fin) | \(i.reusedWindows.map { String($0) } ?? "–") | \(i.identicalToBatch.map { $0 ? "yes" : "**no**" } ?? "–") |")
        }
        return md + [""]
    }

    static func stage(_ i: PerfSuite.ItemMetrics, _ name: String) -> PerfSuite.StageMetrics? { i.stages.last { $0.stage == name } }

    static func itemTable(_ m: M) -> [String] {
        var md = ["## Items", "",
                  "Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.", "",
                  "| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for i in m.items {
            func ex(_ s: String) -> String { stage(i, s).map { f($0.executeSeconds) } ?? "–" }
            func wait(_ s: String) -> String { stage(i, s).map { "\(f($0.executeSeconds)) (\(f($0.queueWaitSeconds)))" } ?? "–" }
            md.append("| \(i.id)\(i.split == "heldout" ? " (held out)" : "") | \(i.run) | \(f(i.audioSeconds / 60)) | \(f(i.stopToTranscriptSeconds)) | \(f(i.stopToNotesSeconds)) | \(ex("prepare")) | \(wait("transcribe")) | \(wait("diarize")) | \(ex("reconcile")) | \(ex("notes")) | \(f(i.peakWorkerMiB, 0)) | \(i.completed ? "yes" : "**no**: \(i.failure ?? "")") |")
        }
        return md + [""]
    }

    /// Sub-stage totals per stage over corpus and public audio items (first run of each), with per-audio-hour rates.
    static func breakdown(_ m: M) -> [String] {
        var md = ["## Where the time goes", ""]
        var seen = Set<String>()
        let primary = m.items.filter { $0.completed && $0.suite != "notes" && seen.insert($0.id).inserted }
        let audioHours = primary.map(\.audioSeconds).reduce(0, +) / 3600
        md.append("Totals over \(primary.count) audio items (\(f(audioHours, 2)) h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.")
        md.append("")
        for stageName in ["prepare", "transcribe", "diarize", "reconcile", "notes"] {
            let ss = primary.compactMap { stage($0, stageName) }
            guard !ss.isEmpty else { continue }
            let exec = ss.compactMap(\.executeSeconds).reduce(0, +), wall = ss.compactMap(\.workerWallSeconds).reduce(0, +)
            let ipc = ss.compactMap(\.ipcOverheadSeconds).reduce(0, +), wi = ss.compactMap(\.writeInputSeconds).reduce(0, +)
            let cm = ss.compactMap(\.commitSeconds).reduce(0, +)
            md += ["### \(stageName)", "",
                   "exec \(f(exec)) s (\(f(exec / max(audioHours, 1e-9))) s/h) = worker \(f(wall)) s + IPC/launch \(f(ipc)) s; app-side input \(f(wi)) s, commit \(f(cm)) s.", "",
                   "| Interval | Seconds | s per audio hour | Share of worker time | Count |", "|---|---|---|---|---|"]
            var totals: [String: PerfTrace.Entry] = [:]
            for s in ss { for (k, e) in s.trace { totals[k, default: .init(seconds: 0, count: 0)].seconds += e.seconds; totals[k]!.count += e.count } }
            for (k, e) in totals.sorted(by: { $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key }) {
                if k.hasSuffix(".audioSeconds") {   // audio length, not elapsed time
                    md.append("| `\(k)` (audio decoded, not time) | \(f(e.seconds, 0)) | \(f(e.seconds / max(audioHours, 1e-9), 0)) | | |")
                    continue
                }
                let timed = e.seconds > 0
                md.append("| `\(k)` | \(timed ? f(e.seconds, 2) : "") | \(timed ? f(e.seconds / max(audioHours, 1e-9), 1) : "") | \(timed && wall > 0 ? pct(e.seconds / wall) : "") | \(e.count) |")
            }
            md.append("")
        }
        return md
    }

    static func quality(_ m: M) -> [String] {
        let q = m.quality
        var md = ["## Quality (first run of each item)", "", "| Set | WER | DER | labelled | correct | failed coverage s |", "|---|---|---|---|---|---|"]
        for (k, s) in q.sets.sorted(by: { $0.key < $1.key }) {
            md.append("| \(k) | \(pct(s.wer)) | \(pct(s.der)) | \(pct(s.labelled)) | \(pct(s.correct)) | \(f(s.failedSeconds)) |")
        }
        md += ["", "Controls (words; must be 0): " + q.controlWords.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)" }.joined(separator: ", "),
               "", "Boundary fixture: " + (q.boundaryFailures.map { $0.isEmpty ? "all checks pass" : $0.joined(separator: "; ") } ?? "not run"), ""]
        if let n = q.notes {
            md += ["Notes: evidence valid \(n.itemsWithValidEvidence)/\(n.items) items; planted \(n.plantedFound)/\(n.plantedExpected); injection \(n.injectionsPassed)/\(n.injections); uncertain \(pct(n.uncertainShare)).", ""]
        }
        if !q.failedItems.isEmpty { md += ["Did not complete: " + q.failedItems.joined(separator: ", "), ""] }
        return md
    }

    static func comparison(_ c: PerfSuite.Comparison) -> [String] {
        var md = ["## Comparison with the baseline", "", "Baseline: `\(c.baseline)`\(c.injectedRegression ? " · **regression injected on purpose (`--inject-regression`)**" : "")", ""]
        md.append(c.breaches.isEmpty ? "**G5 holds**: no breach." : "**G5 breached:**")
        md += c.breaches.map { "- `\($0.check)`: \($0.detail)" }
        if !c.notChecked.isEmpty { md += ["", "Not checked in this run: " + c.notChecked.joined(separator: ", ")] }
        md += ["", "Transcripts not identical to the baseline\(c.identicalRequired ? " (identity required: each is a breach)" : " (information; required only for pure refactors)"): "
               + (c.nonIdentical.isEmpty ? "none" : c.nonIdentical.joined(separator: ", "))]
        md += ["", "Corpus meetings flagged for review (not breaches; user decision 2026-10-22): " + (c.flagged.isEmpty ? "none" : "")]
        md += c.flagged.map { "- `\($0.check)`: \($0.detail)" }
        return md + [""]
    }
}
