@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import BenchEngines
import Domain
import Notes
import Scoring

/// T16 `amaranth-bench perf-suite` (docs/milestone-e-performance-plan.md):
///
///     perf-suite run --app <Amaranth.app> [--suites public,corpus,notes[,incremental][,yield]] [--only id,…] [--speed 20]
///                    [--live-speed 10] [--results <dir>]
///                    [--compare <baseline>] [--require-identical]
///     perf-suite score <results> [--compare <baseline>] [--inject-regression] [--require-identical]
///     perf-suite freeze <results> <baseline> [--noise <second results>]
///
/// `run` builds the items (public suite, user corpus from `Tests/Data/Recordings/manifest.csv`, notes fixtures), has
/// the app replay them through the real capture path, XPC worker and scheduler (`--self-test perf-run`), then scores
/// them: `measurements.json` (machine-readable) and `report.md` (per-stage times, G1–G7 status, quality, flags).
/// Reports hold metrics and meeting IDs only, never transcript text (plan §10). `--compare` exits 1 on any G5 breach.
enum PerfSuite {
    static let repo = URL(filePath: FileManager.default.currentDirectoryPath)
    static var fixtures: URL { repo.appending(path: "Benchmarks/Fixtures/public") }
    static var corpus: URL { repo.appending(path: "Tests/Data/Recordings") }
    static var cache: URL { corpus.appending(path: ".perf-cache") }
    static var t02Inputs: URL { repo.appending(path: "Benchmarks/Results/2026-10-16-t02-run1/inputs") }

    static func main(_ args: [String]) async throws -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let compare = value("--compare").map { URL(filePath: $0) }
        let requireIdentical = args.contains("--require-identical")
        switch args.first {
        case "run":
            guard let app = value("--app") else { print("perf-suite run: --app <Amaranth.app> required"); return 2 }
            let suites = Set((value("--suites") ?? "public,corpus,notes").split(separator: ",").map(String.init))
            let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
            let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let results = URL(filePath: value("--results") ?? "Benchmarks/Results/\(date)-perf")
            var items = try await buildItems(suites: suites)
            if let only { items = items.filter { only.contains($0.item.id) } }
            guard !items.isEmpty else { print("perf-suite: no items"); return 2 }
            // The first item runs on a fresh worker (cold); the two-source timing meeting is also repeated warm.
            items[0].item.coldWorker = true
            try runApp(app: URL(filePath: app), items: items, results: results, speed: Double(value("--speed") ?? "20") ?? 20,
                       liveSpeed: Double(value("--live-speed") ?? "10") ?? 10)
            return try score(results: results, compare: compare, inject: false, requireIdentical: requireIdentical)
        case "score" where args.count >= 2:
            return try score(results: URL(filePath: args[1]), compare: compare, inject: args.contains("--inject-regression"),
                             requireIdentical: requireIdentical)
        case "freeze" where args.count >= 3:
            try freeze(results: URL(filePath: args[1]), baseline: URL(filePath: args[2]), noise: value("--noise").map { URL(filePath: $0) })
            return 0
        default:
            print("usage: amaranth-bench perf-suite run|score|freeze … (see Benchmarks/Harness/PerfSuite.swift)")
            return 2
        }
    }

    // MARK: Items

    /// An item plus what scoring needs to know about it (persisted as `items.json` beside the outputs).
    struct SuiteItem: Codable, Sendable {
        var item: PerfRun.Item
        /// "public", "corpus" or "notes".
        var suite: String
        /// Scoring set: librispeech, ami-clean, ami-difficult, control, boundary, corpus, notes-planted, notes-injection.
        var set: String
        var audioSeconds: Double
        /// public: reference text file / AMI meeting; notes: expected planted cut-off or injection keyword.
        var reference: String?
        var amiMeeting: String?
        var split: String?
    }

    static func buildItems(suites: Set<String>) async throws -> [SuiteItem] {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var out: [SuiteItem] = []
        if suites.contains("public") { out += try publicItems() }
        if suites.contains("corpus") { out += try await corpusItems() }
        if suites.contains("notes") { out += try notesItems() }
        if suites.contains("yield") { out += try yieldItems() }
        if suites.contains("incremental") {
            // T19 (opt-in): the 60-minute meeting is also replayed as a recording in progress, and back to back.
            for i in out.indices where out[i].item.id == "timing-2src-60min" { out[i].item.whileRecording = true; out[i].item.backToBack = true }
        }
        return out
    }

    /// 16 kHz mono float samples → raw cache file.
    static func raw16k(_ samples: [Float], id: String) throws -> PerfRun.RawAudio {
        let url = cache.appending(path: "\(id)-16k-mono.f32")
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)
        return PerfRun.RawAudio(path: url.path, sampleRate: 16_000, channels: 1)
    }

    /// Two-source timing meeting, built like the 2026-10-16 processing-timing evidence (QualificationSelfTest.sources):
    /// mic = LibriSpeech utterances with 2–6 s pauses, looped; system = ES2004a, IS1009a, EN2002a looped. Timing only.
    static func timingMeeting(seconds: Int) throws -> (system: [Float], mic: [Float]) {
        let n = seconds * 16_000
        var utterances: [[Float]] = []
        for (spk, ch) in [("1089", "134686"), ("121", "121726")] {
            let dir = fixtures.appending(path: "librispeech-test-clean/\(spk)/\(ch)")
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".flac") }).sorted() {
                utterances.append(try BenchAudio.load16kMono(dir.appending(path: f)))
            }
        }
        var tmic: [Float] = [], i = 0
        while tmic.count < n { tmic += utterances[i % utterances.count] + [Float](repeating: 0, count: 16_000 * (2 + i % 5)); i += 1 }
        let meetings = try ["ES2004a", "IS1009a", "EN2002a"].map { try BenchAudio.load16kMono(fixtures.appending(path: "ami/\($0)/\($0).Mix-Headset.wav")) }
        var tsys: [Float] = []
        i = 0
        while tsys.count < n { tsys += meetings[i % meetings.count]; i += 1 }
        return (Array(tsys.prefix(n)), Array(tmic.prefix(n)))
    }

    static func publicItems() throws -> [SuiteItem] {
        var out: [SuiteItem] = []
        let (tsys, tmic) = try timingMeeting(seconds: 3600)
        out.append(SuiteItem(item: PerfRun.Item(id: "timing-2src-60min", kind: .audio, system: try raw16k(tsys, id: "timing-2src-60min-sys"),
                                                microphone: try raw16k(tmic, id: "timing-2src-60min-mic"), notes: true, repeatWarm: true),
                             suite: "public", set: "timing", audioSeconds: 3600))
        for (m, file, set) in [("ES2004a", "Mix-Headset", "ami-clean"), ("IS1009a", "Mix-Headset", "ami-clean"),
                               ("EN2002a", "Mix-Headset", "ami-clean"), ("ES2004a", "Array1-01", "ami-difficult")] {
            let id = "ami-\(m)-\(file == "Mix-Headset" ? "mix" : "array")"
            let s = try BenchAudio.load16kMono(fixtures.appending(path: "ami/\(m)/\(m).\(file).wav"))
            out.append(SuiteItem(item: PerfRun.Item(id: id, kind: .audio, system: try raw16k(s, id: id), notes: false), suite: "public", set: set,
                                 audioSeconds: Double(s.count) / 16_000, amiMeeting: m))
        }
        // LibriSpeech through the microphone path: 25 utterances with 1.5 s pauses.
        var mic: [Float] = [], refs: [String] = []
        for (spk, ch) in [("1089", "134686"), ("121", "121726")] {
            let dir = fixtures.appending(path: "librispeech-test-clean/\(spk)/\(ch)")
            let trans = try String(contentsOf: dir.appending(path: "\(spk)-\(ch).trans.txt"), encoding: .utf8)
            for line in trans.split(separator: "\n").prefix(spk == "1089" ? 10 : 15) {
                let parts = line.split(separator: " ", maxSplits: 1)
                mic += try BenchAudio.load16kMono(dir.appending(path: "\(parts[0]).flac")) + [Float](repeating: 0, count: 24_000)
                refs.append(String(parts[1]))
            }
        }
        let refURL = cache.appending(path: "libri-mic.ref.txt")
        try refs.joined(separator: " ").write(to: refURL, atomically: true, encoding: .utf8)
        out.append(SuiteItem(item: PerfRun.Item(id: "libri-mic", kind: .audio, microphone: try raw16k(mic, id: "libri-mic"), notes: false),
                             suite: "public", set: "librispeech", audioSeconds: Double(mic.count) / 16_000, reference: refURL.path))
        for c in ["silence", "noise", "music"] {
            let s = try BenchAudio.load16kMono(t02Inputs.appending(path: "control-\(c).wav"))
            out.append(SuiteItem(item: PerfRun.Item(id: "control-\(c)", kind: .audio, system: try raw16k(s, id: "control-\(c)"), notes: false),
                                 suite: "public", set: "control", audioSeconds: Double(s.count) / 16_000))
        }
        // Boundary fixture (same text and checks as ASRTests.boundariesPreserveNumbersDatesAndNegationsWithoutDuplicates).
        let tts = cache.appending(path: "boundary-tts.wav")
        if !FileManager.default.fileExists(atPath: tts.path) {
            let say = Process()
            say.executableURL = URL(filePath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-r", "200", "-o", tts.path, "--data-format=LEI16@16000", Boundary.reference]
            try say.run(); say.waitUntilExit()
        }
        let b = try BenchAudio.load16kMono(tts) + [Float](repeating: 0, count: 16_000)
        out.append(SuiteItem(item: PerfRun.Item(id: "boundary-tts", kind: .audio, system: try raw16k(b, id: "boundary-tts"), notes: false),
                             suite: "public", set: "boundary", audioSeconds: Double(b.count) / 16_000))
        return out
    }

    struct ManifestRow { var id: String; var fields: [String: String] }

    static func manifest() throws -> [ManifestRow] {
        let text = try String(contentsOf: corpus.appending(path: "manifest.csv"), encoding: .utf8)
        var rows: [[String]] = []
        var row: [String] = [], field = "", quoted = false
        var chars = Array(text)
        if chars.last != "\n" { chars.append("\n") }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } } else { field.append(c) }
            } else if c == "\"" { quoted = true
            } else if c == "," { row.append(field); field = ""
            } else if c == "\n" { row.append(field); field = ""; if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []
            } else if c != "\r" { field.append(c) }
            i += 1
        }
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            var f: [String: String] = [:]
            for (k, v) in zip(header, r) { f[k] = v }
            return ManifestRow(id: f["file_or_amaranth_title"] ?? "", fields: f)
        }
    }

    /// Stable, filesystem-safe item ID for a corpus entry (file stem or title).
    static func slug(_ s: String) -> String {
        let stem = (s as NSString).deletingPathExtension
        let base = FileManager.default.fileExists(atPath: corpus.appending(path: s).path) ? stem : s
        return "corpus-" + base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { if !($1 == "-" && $0.last == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Blank `split` in the manifest: a stable assignment from the item ID (about one meeting in four held out), so a
    /// meeting never moves between dev and held-out as the corpus grows.
    static func autoSplit(_ id: String) -> String {
        let h = id.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }   // FNV-1a
        return h % 4 == 0 ? "heldout" : "dev"
    }

    static func corpusItems() async throws -> [SuiteItem] {
        var out: [SuiteItem] = []
        let ownLibrary = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Amaranth")
        var libraryCopies: [URL: URL] = [:]
        for row in try manifest() {
            guard row.fields["consent"]?.lowercased() == "yes" else { print("[perf] skipping \(row.id): no consent"); continue }
            let id = slug(row.id)
            let split = row.fields["split"].flatMap { $0.isEmpty ? nil : $0 } ?? autoSplit(id)
            let file = corpus.appending(path: row.id)
            if FileManager.default.fileExists(atPath: file.path) {
                let raw = try await decode48kStereo(file, id: id)
                let secs = Double((try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int) ?? 0) / 4 / 2 / 48_000
                // Mixed single-track recordings are fed as system audio (see the plan's corpus notes).
                out.append(SuiteItem(item: PerfRun.Item(id: id, kind: .audio, system: raw, notes: true), suite: "corpus", set: "corpus",
                                     audioSeconds: secs, split: split))
            } else {
                // An Amaranth-recorded meeting by title (or meeting ID), from a private copy of the library (never opened in
                // place). `library` names a library brought from another Mac (relative to the corpus folder); blank is this Mac's.
                let library = row.fields["library"].flatMap { $0.isEmpty ? nil : $0 }
                    .map { $0.hasPrefix("/") ? URL(filePath: $0) : corpus.appending(path: $0) } ?? ownLibrary
                if libraryCopies[library] == nil { libraryCopies[library] = try copyLibrary(library, index: libraryCopies.count) }
                guard let copy = libraryCopies[library], let meeting = try meetingID(title: row.id, library: copy) else {
                    print("[perf] skipping \(row.id): not a file and not a meeting in \(library.path)"); continue
                }
                try FileManager.default.copyItem(at: library.appending(path: "meetings/\(meeting)"), to: copy.appending(path: "meetings/\(meeting)"))
                out.append(SuiteItem(item: PerfRun.Item(id: id, kind: .amaranthMeeting, library: copy.path, meetingID: meeting, notes: true),
                                     suite: "corpus", set: "corpus", audioSeconds: Double(row.fields["duration_s"] ?? "") ?? 0, split: split))
            }
        }
        return out
    }

    /// Copies the library database (with its WAL) into the cache; meeting folders are copied per item.
    static func copyLibrary(_ library: URL, index: Int) throws -> URL {
        let copy = cache.appending(path: index == 0 ? "library-copy" : "library-copy-\(index)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.createDirectory(at: copy.appending(path: "meetings"), withIntermediateDirectories: true)
        for f in ["amaranth.sqlite", "amaranth.sqlite-wal", "amaranth.sqlite-shm"] where FileManager.default.fileExists(atPath: library.appending(path: f).path) {
            try FileManager.default.copyItem(at: library.appending(path: f), to: copy.appending(path: f))
        }
        return copy
    }

    static func meetingID(title: String, library: URL) throws -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", library.appending(path: "amaranth.sqlite").path, "SELECT json FROM meetings"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let m = try? ContractCoding.decode(Meeting.self, from: Data(line.utf8)), m.deletedAt == nil, m.title == title || m.id.rawValue == title { return m.id.rawValue }
        }
        return nil
    }

    /// Decodes any AVFoundation-readable file (audio or video) to 48 kHz stereo interleaved float32, cached by size/mtime.
    static func decode48kStereo(_ url: URL, id: String) async throws -> PerfRun.RawAudio {
        let out = cache.appending(path: "\(id)-48k-stereo.f32"), stamp = cache.appending(path: "\(id)-48k-stereo.source")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.lastPathComponent) \(attrs[.size] ?? 0) \((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let raw = PerfRun.RawAudio(path: out.path, sampleRate: 48_000, channels: 2)
        if (try? String(contentsOf: stamp, encoding: .utf8)) == key, FileManager.default.fileExists(atPath: out.path) { return raw }
        print("[perf] decoding \(url.lastPathComponent)")
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw BenchError.audio("no audio track in \(url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw BenchError.audio("reader: \(reader.error.map { "\($0)" } ?? "?")") }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        while let buf = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
                try h.write(contentsOf: Data(bytes: ptr, count: length))
            } else {
                var d = Data(count: length)
                d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                try h.write(contentsOf: d)
            }
        }
        guard reader.status == .completed else { throw BenchError.audio("decode failed: \(reader.error.map { "\($0)" } ?? "?")") }
        try key.write(to: stamp, atomically: true, encoding: .utf8)
        return raw
    }

    /// Notes fixtures from NotesEval: planted facts (60 and 120 min of AMI reference speech) and the injection suite.
    static func notesItems() throws -> [SuiteItem] {
        var out: [SuiteItem] = []
        for (label, cut) in [("60min", 3600.0), ("120min", 7200.0)] {
            let tr = try NotesFixtures.planted(cut: cut, fixtures: fixtures)
            let url = cache.appending(path: "notes-planted-\(label).json")
            try ContractCoding.encode(tr).write(to: url)
            out.append(SuiteItem(item: PerfRun.Item(id: "notes-planted-\(label)", kind: .notesTranscript, transcript: url.path, notes: true),
                                 suite: "notes", set: "notes-planted", audioSeconds: cut, reference: "\(cut)"))
        }
        for (i, (_, keyword)) in NotesEval.injections.enumerated() {
            let tr = try NotesFixtures.injection(i, fixtures: fixtures)
            let url = cache.appending(path: "notes-inject-\(i).json")
            try ContractCoding.encode(tr).write(to: url)
            out.append(SuiteItem(item: PerfRun.Item(id: "notes-inject-\(i)", kind: .notesTranscript, transcript: url.path, notes: true),
                                 suite: "notes", set: "notes-injection", audioSeconds: 600, reference: keyword))
        }
        return out
    }

    /// T18 priority check (not in the default suites, not part of G5): a 14-minute AMI meeting arrives while notes for
    /// the 120-minute planted transcript are generating. Compare its transcript time with `ami-IS1009a-mix`.
    static func yieldItems() throws -> [SuiteItem] {
        let notes = try NotesFixtures.planted(cut: 7200, fixtures: fixtures)
        let url = cache.appending(path: "yield-background-notes.json")
        try ContractCoding.encode(notes).write(to: url)
        let id = "yield-ami-IS1009a-during-notes"
        let s = try BenchAudio.load16kMono(fixtures.appending(path: "ami/IS1009a/IS1009a.Mix-Headset.wav"))
        return [SuiteItem(item: PerfRun.Item(id: id, kind: .audio, system: try raw16k(s, id: id), notes: false, duringNotesOf: url.path),
                          suite: "yield", set: "yield", audioSeconds: Double(s.count) / 16_000)]
    }

    // MARK: Run

    static func runApp(app: URL, items: [SuiteItem], results: URL, speed: Double, liveSpeed: Double) throws {
        let outputs = results.appending(path: "outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(items).write(to: results.appending(path: "items.json"))
        let spec = PerfRun.Spec(items: items.map(\.item), outputDirectory: outputs.path, speed: speed,
                                captureCache: corpus.appending(path: ".perf-cache/captures").path, liveSpeed: liveSpeed)
        let specURL = results.appending(path: "perf-spec.json")
        try ContractCoding.encode(spec).write(to: specURL)
        try app.path.write(to: results.appending(path: "app-path.txt"), atomically: true, encoding: .utf8)
        let log = results.appending(path: "perf-run.jsonl")
        print("[perf] running \(items.count) items through \(app.lastPathComponent) (log: \(log.path))")
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        p.arguments = ["-W", "-n", app.path, "--args", "--self-test", "perf-run", "--perf-spec", specURL.path, "--self-test-output", log.path]
        try p.run()
        p.waitUntilExit()
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
        print("[perf] app finished: \(lines.last ?? "no output")")
    }

    // MARK: Scoring

    struct StageMetrics: Codable {
        var stage: String
        var state: String
        var errorCode: String?
        var queueWaitSeconds: Double?
        var writeInputSeconds: Double?
        var executeSeconds: Double?
        var commitSeconds: Double?
        var workerWallSeconds: Double?
        /// XPC round trip minus the worker's own stage time (IPC, encoding, process launch).
        var ipcOverheadSeconds: Double?
        var workerUptimeSeconds: Double?
        var qos: String?
        var build: String?
        var thermal: String?
        var trace: [String: PerfTrace.Entry]
        var traceNotes: [String: String]
    }

    struct NotesMetrics: Codable {
        var items: Int
        var itemsWithValidEvidence: Int
        var uncertain: Int
        var plantedFound: Int?
        var plantedExpected: Int?
        var injectionPassed: Bool?
    }

    struct ItemMetrics: Codable {
        var id: String
        var run: String
        var suite: String
        var set: String
        var split: String?
        var completed: Bool
        var failure: String?
        var audioSeconds: Double
        var recordWallSeconds: Double?
        var stopToTranscriptSeconds: Double?
        var stopToNotesSeconds: Double?
        var peakAppMiB: Double
        var peakWorkerMiB: Double
        var stages: [StageMetrics]
        var words: Int?
        var speakers: Int?
        var failedCoverageSeconds: Double?
        var transcriptHash: String?
        var asrHash: String?
        var wer: WER.Result?
        var der: DER.Result?
        /// Single-speaker reference words, of which labelled, of which correct (plan §10 attribution).
        var attribution: [Int]?
        var boundaryFailures: [String]?
        var notes: NotesMetrics?
        // Filled by --compare.
        var identicalToBaseline: Bool?
        var wordAgreement: Double?
        var speakerAgreement: Double?
        var notesOverlap: Double?
        // T19: processing while recording.
        var incremental: PerfRun.Incremental?
        var reusedWindows: Int?
        var identicalToBatch: Bool?
        var nextStopSeconds: Double?
        var transcriptReadyBeforeNextStop: Bool?
        var transcriptJobsLeftAtNextStop: Int?
    }

    struct Comparison: Codable {
        var baseline: String
        var breaches: [PerfGuard.Finding]
        var notChecked: [String]
        var flagged: [PerfGuard.Finding]
        var nonIdentical: [String]
        var identicalRequired: Bool
        var injectedRegression: Bool
    }

    struct Measurements: Codable {
        var created: Date
        var host: [String: String]
        var items: [ItemMetrics]
        var quality: PerfGuard.Quality
        var comparison: Comparison?
    }

    struct Loaded {
        var result: PerfRun.ItemResult
        var asr: TranscriptRevision?
        var transcript: TranscriptRevision?
        var diarization: [DiarizationResult]?
        var summary: SummaryRevision?
    }

    static func load(_ dir: URL) -> Loaded? {
        func get<T: Codable & Sendable>(_ name: String) -> T? { try? ContractCoding.decode(T.self, from: Data(contentsOf: dir.appending(path: name))) }
        guard let r: PerfRun.ItemResult = get("result.json") else { return nil }
        return Loaded(result: r, asr: get("asr.json"), transcript: get("transcript.json"), diarization: get("diarization.json"), summary: get("summary.json"))
    }

    static func runs(_ outputs: URL, _ id: String) -> [URL] {
        let dir = outputs.appending(path: id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().map { dir.appending(path: $0) }
    }

    static func score(results: URL, compare: URL?, inject: Bool, requireIdentical: Bool) throws -> Int32 {
        let items = try JSONDecoder().decode([SuiteItem].self, from: Data(contentsOf: results.appending(path: "items.json")))
        let outputs = results.appending(path: "outputs")
        var metrics: [ItemMetrics] = []
        for si in items {
            for dir in runs(outputs, si.item.id) {
                guard var l = load(dir) else { continue }
                if inject { injectRegression(&l, si) }
                metrics.append(try scoreItem(si, l))
            }
            // T19: a run replayed as a recording in progress must give exactly the item's batch transcript.
            let mine = metrics.indices.filter { metrics[$0].id == si.item.id }
            if let batch = mine.map({ metrics[$0] }).first(where: { !PerfReport.isIncremental($0) }) {
                for i in mine where PerfReport.isIncremental(metrics[i]) { metrics[i].identicalToBatch = metrics[i].transcriptHash == batch.transcriptHash }
            }
            if runs(outputs, si.item.id).isEmpty {
                metrics.append(ItemMetrics(id: si.item.id, run: "missing", suite: si.suite, set: si.set, split: si.split, completed: false,
                                           failure: "no output", audioSeconds: si.audioSeconds, peakAppMiB: 0, peakWorkerMiB: 0, stages: []))
            }
        }
        let quality = aggregate(metrics)
        var m = Measurements(created: Date(), host: host(), items: metrics, quality: quality)
        var exit: Int32 = metrics.allSatisfy(\.completed) ? 0 : 1
        if let compare {
            let base = try JSONDecoder.iso.decode(Measurements.self, from: Data(contentsOf: compare.appending(path: "measurements.json")))
            let info = try? JSONDecoder.iso.decode(BaselineInfo.self, from: Data(contentsOf: compare.appending(path: "baseline.json")))
            var flagged: [PerfGuard.Finding] = [], nonIdentical: [String] = []
            for i in m.items.indices {
                let it = m.items[i]
                guard let b = base.items.first(where: { $0.id == it.id && $0.run == it.run }) ?? base.items.first(where: { $0.id == it.id }) else { continue }
                let noisy = info?.nonDeterministic.contains(it.id) ?? false
                m.items[i].identicalToBaseline = it.transcriptHash == b.transcriptHash
                if it.transcriptHash != b.transcriptHash && !noisy { nonIdentical.append("\(it.id)/\(it.run)") }
                if it.suite == "corpus", let cur = load(outputs.appending(path: "\(it.id)/\(it.run)")),
                   let old = load(compare.appending(path: "outputs/\(it.id)/\(b.run)")) {
                    m.items[i].wordAgreement = wordAgreement(old.transcript, cur.transcript)
                    m.items[i].speakerAgreement = speakerAgreement(old.transcript, cur.transcript)
                    m.items[i].notesOverlap = notesOverlap(old.summary, cur.summary)
                    flagged += PerfGuard.corpusFlags(id: it.id, wordAgreement: m.items[i].wordAgreement, speakerAgreement: m.items[i].speakerAgreement,
                                                     notesOverlap: m.items[i].notesOverlap)
                }
            }
            var breaches = PerfGuard.evaluate(baseline: base.quality, current: quality)
            if requireIdentical { breaches += nonIdentical.map { PerfGuard.Finding(check: "identical", detail: "\($0) differs from the baseline") } }
            m.comparison = Comparison(baseline: compare.path, breaches: breaches, notChecked: PerfGuard.notChecked(baseline: base.quality, current: quality),
                                      flagged: flagged, nonIdentical: nonIdentical, identicalRequired: requireIdentical, injectedRegression: inject)
            if !breaches.isEmpty { exit = 1 }
        }
        try JSONEncoder.pretty.encode(m).write(to: results.appending(path: "measurements.json"))
        try PerfReport.markdown(m).write(to: results.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print("[perf] wrote \(results.appending(path: "report.md").path)")
        if let c = m.comparison {
            print("[perf] G5: \(c.breaches.isEmpty ? "PASS" : "FAIL") — \(c.breaches.count) breaches, \(c.flagged.count) corpus flags, \(c.nonIdentical.count) non-identical")
            for b in c.breaches { print("[perf]   breach \(b.check): \(b.detail)") }
        }
        return exit
    }

    /// `--inject-regression`: deletes every 10th word of public-suite transcripts and adds a word to the silence control,
    /// so the comparison can be shown to fail.
    static func injectRegression(_ l: inout Loaded, _ si: SuiteItem) {
        guard si.suite == "public", var t = l.transcript else { return }
        var n = 0
        for s in t.segments.indices { t.segments[s].words = t.segments[s].words.filter { _ in n += 1; return n % 10 != 0 } }
        if si.item.id == "control-silence", let w = l.asr?.allWords.first ?? t.allWords.first {
            t.segments.append(TranscriptSegment(source: .systemOutput, interval: w.interval, words: [w]))
        } else if si.item.id == "control-silence" {
            let w = Word(text: "injected", interval: .seconds(1, 1.2), source: .systemOutput)
            t.segments.append(TranscriptSegment(source: .systemOutput, interval: w.interval, words: [w]))
        }
        l.transcript = t
    }

    static func scoreItem(_ si: SuiteItem, _ l: Loaded) throws -> ItemMetrics {
        let r = l.result
        var m = ItemMetrics(id: si.item.id, run: r.run, suite: si.suite, set: si.set, split: si.split, completed: r.completed, failure: r.failure,
                            audioSeconds: r.audioSeconds, recordWallSeconds: r.recordWallSeconds, stopToTranscriptSeconds: r.stopToTranscriptSeconds,
                            stopToNotesSeconds: r.stopToNotesSeconds, peakAppMiB: r.peakAppMiB, peakWorkerMiB: r.peakWorkerMiB,
                            stages: r.stages.map(stageMetrics))
        m.incremental = r.incremental
        m.reusedWindows = r.stages.last { $0.stage == "transcribe" }?.worker?.trace.entries["asr.windows.reused"].map(\.count)
        m.nextStopSeconds = r.nextStopSeconds
        m.transcriptReadyBeforeNextStop = r.transcriptReadyBeforeNextStop
        m.transcriptJobsLeftAtNextStop = r.transcriptJobsLeftAtNextStop
        if let t = l.transcript, si.suite != "notes" {
            m.words = t.allWords.count
            m.speakers = t.speakers.count
            m.failedCoverageSeconds = t.coverage.filter { $0.status == .failed }.map(\.interval.duration.seconds).reduce(0, +)
            m.transcriptHash = canonicalHash(t)
        }
        m.asrHash = l.asr.map(canonicalHash)
        let hyp = l.transcript?.allWords.map(\.text).joined(separator: " ") ?? ""
        switch si.set {
        case "librispeech":
            if let ref = si.reference { m.wer = WER.score(reference: try String(contentsOf: URL(filePath: ref), encoding: .utf8), hypothesis: hyp) }
        case "ami-clean", "ami-difficult":
            guard let meeting = si.amiMeeting else { break }
            let dir = fixtures.appending(path: "ami/\(meeting)")
            m.wer = WER.score(reference: try AMIReference(directory: dir, meeting: meeting).text(), hypothesis: hyp)
            let rttm = DER.parseRTTM(try String(contentsOf: dir.appending(path: "\(meeting).only_words.rttm"), encoding: .utf8))
            let uem = DER.parseUEM(try String(contentsOf: dir.appending(path: "\(meeting).uem"), encoding: .utf8))
            if let d = l.diarization?.first(where: { $0.source == .systemOutput }) {
                let der = DER.score(reference: rttm, hypothesis: d.turns.map { DER.Segment(start: $0.interval.start.seconds, end: $0.interval.end.seconds,
                                                                                            speaker: $0.cluster.rawValue) }, uem: uem)
                m.der = der
                if let t = l.transcript { m.attribution = attribution(t, rttm: rttm, mapping: der.mapping) }
            }
        case "boundary":
            m.boundaryFailures = Boundary.failures(hypothesis: hyp)
        default:
            break
        }
        if let s = l.summary {
            let source: TranscriptRevision? = si.suite == "notes" ? si.item.transcript.flatMap {
                try? ContractCoding.decode(TranscriptRevision.self, from: Data(contentsOf: URL(filePath: $0)))
            } : l.transcript
            m.notes = notesMetrics(s, transcript: source, si: si)
        }
        return m
    }

    static func stageMetrics(_ s: PerfRun.StageResult) -> StageMetrics {
        let sch = s.scheduler, w = s.worker
        return StageMetrics(stage: s.stage, state: s.state, errorCode: s.errorCode, queueWaitSeconds: sch.map { $0.startedAt - $0.queuedAt },
                            writeInputSeconds: sch?.writeInputSeconds, executeSeconds: sch?.executeSeconds, commitSeconds: sch?.commitSeconds,
                            workerWallSeconds: w?.wallSeconds, ipcOverheadSeconds: sch.flatMap { s in w.map { s.executeSeconds - $0.wallSeconds } },
                            workerUptimeSeconds: w?.workerUptimeSeconds, qos: w?.qos, build: w?.build, thermal: w.map { "\($0.thermalStart)→\($0.thermalEnd)" },
                            trace: w?.trace.entries ?? [:], traceNotes: w?.trace.notes ?? [:])
    }

    /// Words in single-speaker reference speech that got one speaker label, and how many of those are correct under
    /// DER's optimal mapping (same method as `production-eval`).
    static func attribution(_ t: TranscriptRevision, rttm: [DER.Segment], mapping: [String: String]) -> [Int] {
        var clusterOf: [SpeakerID: String] = [:]
        for sp in t.speakers { if let c = sp.clusters.first { clusterOf[sp.id] = c.cluster.rawValue } }
        var inSingle = 0, labelled = 0, correct = 0
        for word in t.allWords {
            let mid = (word.interval.start.seconds + word.interval.end.seconds) / 2
            let covering = rttm.filter { $0.start <= mid && mid < $0.end }
            guard covering.count == 1, let ref = covering.first?.speaker else { continue }
            inSingle += 1
            if case .speaker(let id) = word.speaker {
                labelled += 1
                if let c = clusterOf[id], mapping[c] == ref { correct += 1 }
            }
        }
        return [inSingle, labelled, correct]
    }

    static func notesMetrics(_ s: SummaryRevision, transcript: TranscriptRevision?, si: SuiteItem) -> NotesMetrics {
        let items = s.content.allItems.filter { $0.kind != .limitation }
        func valid(_ item: SummaryItem) -> Bool {
            guard let t = transcript, !item.evidence.isEmpty else { return false }
            return item.evidence.allSatisfy { ref in
                guard case .transcript(let e) = ref else { return true }
                guard let seg = t.segment(e.segmentID) else { return false }
                return seg.words.contains { $0.id == e.firstWord } && seg.words.contains { $0.id == e.lastWord }
            }
        }
        var m = NotesMetrics(items: items.count, itemsWithValidEvidence: items.filter(valid).count, uncertain: items.filter(\.uncertain).count)
        if si.set == "notes-planted", let t = transcript, let cut = si.reference.flatMap(Double.init) {
            let doc = NotesInputDocument.build(transcript: t, scratchpad: nil)
            var found = 0, expected = 0
            for pl in NotesEval.planted where pl.at < cut {
                expected += 1
                let ids = Set(doc.lines.filter { l in pl.lines.contains { l.text.contains($0.1) } }.map(\.id))
                let segs = Set(doc.lines.filter { ids.contains($0.id) }.flatMap { l -> [TranscriptSegmentID] in
                    if case .spoken(let spans) = l.origin { spans.map(\.segment) } else { [] } })
                if s.content.allItems.contains(where: { item in
                    item.kind == pl.kind && item.text.lowercased().contains(pl.keyword)
                        && item.evidence.contains { if case .transcript(let e) = $0 { segs.contains(e.segmentID) } else { false } }
                }) { found += 1 }
            }
            m.plantedFound = found; m.plantedExpected = expected
        }
        if si.set == "notes-injection", let keyword = si.reference {
            m.injectionPassed = !s.content.allItems.contains { $0.kind != .limitation && $0.text.lowercased().contains(keyword) }
        }
        return m
    }

    static func aggregate(_ items: [ItemMetrics]) -> PerfGuard.Quality {
        var q = PerfGuard.Quality()
        // One run per item counts (the first: cold/default); warm repeats are timing only.
        var seen = Set<String>()
        let primary = items.filter { seen.insert($0.id).inserted }
        for set in ["librispeech", "ami-clean", "ami-difficult"] {
            let its = primary.filter { $0.set == set && $0.completed }
            guard !its.isEmpty else { continue }
            let w = its.compactMap(\.wer).reduce(WER.Result.zero, +)
            let ders = its.compactMap(\.der)
            let refSpeech = ders.map(\.referenceSpeech).reduce(0, +)
            let der = ders.isEmpty || refSpeech == 0 ? nil : ders.map { $0.missed + $0.falseAlarm + $0.confusion }.reduce(0, +) / refSpeech
            let a = its.compactMap(\.attribution).reduce([0, 0, 0]) { [$0[0] + $1[0], $0[1] + $1[1], $0[2] + $1[2]] }
            q.sets[set] = PerfGuard.SetQuality(wer: w.referenceWords > 0 ? w.wer : nil, der: der,
                                               labelled: a[0] > 0 ? Double(a[1]) / Double(a[0]) : nil,
                                               correct: a[1] > 0 ? Double(a[2]) / Double(a[1]) : nil,
                                               failedSeconds: its.compactMap(\.failedCoverageSeconds).reduce(0, +))
        }
        for c in primary where c.set == "control" && c.completed { q.controlWords[String(c.id.dropFirst("control-".count))] = c.words ?? 0 }
        if let b = primary.first(where: { $0.set == "boundary" && $0.completed }) { q.boundaryFailures = b.boundaryFailures ?? [] }
        let notes = primary.compactMap(\.notes)
        if primary.contains(where: { $0.suite == "notes" }) {
            q.notes = PerfGuard.NotesQuality(itemsWithValidEvidence: notes.map(\.itemsWithValidEvidence).reduce(0, +), items: notes.map(\.items).reduce(0, +),
                                             plantedFound: notes.compactMap(\.plantedFound).reduce(0, +),
                                             plantedExpected: notes.compactMap(\.plantedExpected).reduce(0, +),
                                             injectionsPassed: notes.compactMap(\.injectionPassed).filter { $0 }.count,
                                             injections: primary.filter { $0.set == "notes-injection" }.count,
                                             uncertain: notes.map(\.uncertain).reduce(0, +))
        }
        q.failedItems = items.filter { !$0.completed }.map { "\($0.id)/\($0.run)" }
        return q
    }

    // MARK: Agreement with the baseline (unlabelled corpus)

    /// Words, times (ms) and speakers (in order of first appearance) plus coverage: identical outputs hash identically
    /// regardless of random IDs and creation dates.
    static func canonicalHash(_ t: TranscriptRevision) -> String {
        var labels: [String: Int] = [:]
        // Speaker IDs are random per run: label them by first appearance (in `.multiple` too).
        func label(_ s: SpeakerAssignment) -> String {
            if case .unknown = s { return "unknown" }
            return s.speakerIDs.map { id in
                if labels[id.rawValue] == nil { labels[id.rawValue] = labels.count }
                return "s\(labels[id.rawValue]!)"
            }.joined(separator: "+")
        }
        var lines = t.allWords.sorted { ($0.interval.start, $0.source.rawValue) < ($1.interval.start, $1.source.rawValue) }.map {
            "\($0.source.rawValue)|\($0.interval.start.nanoseconds / 1_000_000)|\($0.interval.end.nanoseconds / 1_000_000)|\($0.text)|\(label($0.speaker))|\($0.flags.rawValue)"
        }
        lines += t.coverage.map { "cov|\($0.source.rawValue)|\($0.status.rawValue)|\($0.interval.start.nanoseconds / 1_000_000)|\($0.interval.end.nanoseconds / 1_000_000)" }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func wordAgreement(_ a: TranscriptRevision?, _ b: TranscriptRevision?) -> Double? {
        guard let a, let b else { return nil }
        let r = WER.score(reference: a.allWords.map(\.text).joined(separator: " "), hypothesis: b.allWords.map(\.text).joined(separator: " "))
        return r.referenceWords == 0 ? (r.errors == 0 ? 1 : 0) : max(0, 1 - r.wer)
    }

    static func turns(_ t: TranscriptRevision) -> [DER.Segment] {
        t.allWords.compactMap { w in
            guard case .speaker(let id) = w.speaker else { return nil }
            return DER.Segment(start: w.interval.start.seconds, end: max(w.interval.end.seconds, w.interval.start.seconds + 0.01), speaker: id.rawValue)
        }
    }

    /// 1 − DER of the current speakers against the baseline speakers (optimal mapping), over labelled word time.
    static func speakerAgreement(_ a: TranscriptRevision?, _ b: TranscriptRevision?) -> Double? {
        guard let a, let b else { return nil }
        let ref = turns(a)
        guard !ref.isEmpty else { return nil }
        return max(0, 1 - DER.score(reference: ref, hypothesis: turns(b)).der)
    }

    /// Share of notes items (by kind) matched across the two runs (token Jaccard ≥ 0.5), over the larger count.
    static func notesOverlap(_ a: SummaryRevision?, _ b: SummaryRevision?) -> Double? {
        guard let a, let b else { return nil }
        let ia = a.content.allItems.filter { $0.kind != .limitation }, ib = b.content.allItems.filter { $0.kind != .limitation }
        guard max(ia.count, ib.count) > 0 else { return 1 }
        func tokens(_ s: String) -> Set<String> { Set(WER.normalize(s)) }
        var used = Set<Int>(), matched = 0
        for x in ia {
            let tx = tokens(x.text)
            if let j = ib.indices.first(where: { j in
                !used.contains(j) && ib[j].kind == x.kind && { let ty = tokens(ib[j].text); return Double(tx.intersection(ty).count) / Double(max(1, tx.union(ty).count)) >= 0.5 }()
            }) { used.insert(j); matched += 1 }
        }
        return Double(matched) / Double(max(ia.count, ib.count))
    }

    // MARK: Baseline

    struct BaselineInfo: Codable {
        var created: Date
        var results: String
        var gitCommit: String
        var gitDirty: Bool
        var host: [String: String]
        var build: String
        var modelPack: String
        var modelPackSHA256: String
        var workerBinarySHA256: String?
        /// Producer config hashes found in the outputs (pipeline versions).
        var producers: [String]
        /// Items whose transcript differed between the two baseline runs (`--noise`).
        var nonDeterministic: [String]
    }

    static func freeze(results: URL, baseline: URL, noise: URL?) throws {
        try? FileManager.default.removeItem(at: baseline)
        try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: results.appending(path: "outputs"), to: baseline.appending(path: "outputs"))
        for f in ["measurements.json", "items.json", "report.md"] {
            try FileManager.default.copyItem(at: results.appending(path: f), to: baseline.appending(path: f))
        }
        let m = try JSONDecoder.iso.decode(Measurements.self, from: Data(contentsOf: results.appending(path: "measurements.json")))
        var nonDet: [String] = []
        if let noise {
            let n = try JSONDecoder.iso.decode(Measurements.self, from: Data(contentsOf: noise.appending(path: "measurements.json")))
            for it in m.items {
                guard let o = n.items.first(where: { $0.id == it.id && $0.run == it.run }) ?? n.items.first(where: { $0.id == it.id }) else { continue }
                if o.transcriptHash != it.transcriptHash { nonDet.append(it.id) }
            }
        }
        var producers = Set<String>()
        for si in try JSONDecoder().decode([SuiteItem].self, from: Data(contentsOf: results.appending(path: "items.json"))) {
            for dir in runs(results.appending(path: "outputs"), si.item.id) {
                guard let l = load(dir) else { continue }
                for p in [l.asr?.producer, l.transcript?.producer, l.summary?.producer].compactMap({ $0 }) { producers.insert("\(p.component) \(p.configHash)") }
                for d in l.diarization ?? [] { producers.insert("\(d.producer.component) \(d.producer.configHash)") }
            }
        }
        let models = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Amaranth/Models")
        let active = (try? String(contentsOf: models.appending(path: "active.json"), encoding: .utf8)) ?? ""
        let packJSON = try? Data(contentsOf: packDirectory(models).appending(path: "pack.json"))
        let worker = ((try? String(contentsOf: results.appending(path: "app-path.txt"), encoding: .utf8))
            .map { URL(filePath: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })?
            .appending(path: "Contents/XPCServices/com.alexmartin.amaranth.InferenceWorker.xpc/Contents/MacOS/com.alexmartin.amaranth.InferenceWorker")
        let info = BaselineInfo(created: Date(), results: results.path, gitCommit: shell("/usr/bin/git", ["rev-parse", "HEAD"]),
                                gitDirty: !shell("/usr/bin/git", ["status", "--porcelain", "--untracked-files=no"]).isEmpty, host: m.host,
                                build: Set(m.items.flatMap { $0.stages.compactMap(\.build) }).sorted().joined(separator: ","),
                                modelPack: active, modelPackSHA256: packJSON.map(sha256) ?? "unknown",
                                workerBinarySHA256: worker.flatMap { try? Data(contentsOf: $0) }.map(sha256), producers: producers.sorted(),
                                nonDeterministic: nonDet)
        try JSONEncoder.pretty.encode(info).write(to: baseline.appending(path: "baseline.json"))
        print("[perf] baseline frozen at \(baseline.path) (\(m.items.count) item runs; non-deterministic: \(nonDet.isEmpty ? "none" : nonDet.joined(separator: ", ")))")
    }

    static func packDirectory(_ models: URL) -> URL {
        struct Active: Codable, Sendable { var packID: String; var version: String }
        guard let a = try? ContractCoding.decode(Active.self, from: Data(contentsOf: models.appending(path: "active.json"))) else { return models }
        return models.appending(path: "packs/\(a.packID)/\(a.version)")
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func shell(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func host() -> [String: String] {
        ["os": shell("/usr/bin/sw_vers", ["-productVersion"]) + " " + shell("/usr/bin/sw_vers", ["-buildVersion"]),
         "cpu": shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
         "memoryGB": String(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
         "power": shell("/usr/bin/pmset", ["-g", "batt"]).split(separator: "\n").first.map(String.init) ?? "",
         "git": shell("/usr/bin/git", ["rev-parse", "--short", "HEAD"])]
    }
}

/// The ASR boundary fixture (shared text and checks with `ASRTests`).
enum Boundary {
    static let reference = """
        On March third the team did not ship forty two units because the vendor never confirmed the order. \
        We will not accept a delay beyond the fifteenth of April and there is no budget for a second shipment. \
        Please do not approve any invoice above nine thousand five hundred dollars until the twenty first. \
        The meeting moved from seven thirty to eight fifteen and nobody objected to the new time. \
        Sarah said the numbers were never final and the forecast of sixty percent is not guaranteed.
        """

    /// Failed checks, by name only (no transcript text).
    static func failures(hypothesis hyp: String) -> [String] {
        var out: [String] = []
        let lower = hyp.lowercased()
        for (name, fact) in [("march-3", #"march (3|third)"#), ("42", #"\b(42|forty[- ]two)\b"#), ("15-april", #"(15th|15|fifteenth) (of )?april"#),
                             ("9500", #"(9,500|9500|nine thousand five hundred)"#), ("21st", #"(21st|twenty[- ]first)"#),
                             ("7:30", #"(7[.:]30|seven thirty)"#), ("8:15", #"(8[.:]15|eight fifteen)"#), ("60%", #"(60|sixty) ?(%|percent)"#)]
        where lower.range(of: fact, options: .regularExpression) == nil {
            out.append("fact \(name) lost")
        }
        let h = WER.normalize(hyp), ref = WER.normalize(reference)
        for neg in ["not", "never", "no", "nobody"] where h.filter({ $0 == neg }).count != ref.filter({ $0 == neg }).count {
            out.append("negation '\(neg)' count \(ref.filter { $0 == neg }.count) → \(h.filter { $0 == neg }.count)")
        }
        if zip(h, h.dropFirst()).contains(where: { $0 == $1 }) { out.append("duplicated word at an overlap") }
        if h.prefix(2) != ref.prefix(2) { out.append("opening words") }
        if h.suffix(3) != ref.suffix(3) { out.append("closing words") }
        if WER.score(reference: reference, hypothesis: hyp).wer >= 0.10 { out.append("WER ≥ 10%") }
        return out
    }
}

/// Notes fixtures shared with NotesEval (same construction, so planted lines and IDs match its scoring).
enum NotesFixtures {
    static func planted(cut: Double, fixtures: URL) throws -> TranscriptRevision {
        var b = NotesEval.Builder()
        var t = 0.0
        let windows = NotesEval.planted.map { ($0.at - 5, $0.at + 20) }
        while t < 7200 {
            for m in ["ES2004a", "IS1009a", "EN2002a"] where t < 7200 {
                t = try NotesEval.addAMI(&b, fixtures: fixtures, meeting: m, offset: t, skip: { s in windows.contains { s >= $0.0 && s < $0.1 } }) + 2
            }
        }
        for p in NotesEval.planted { for (i, l) in p.lines.enumerated() { b.addLine(l.0, l.1, at: p.at + Double(i) * 6) } }
        var tr = b.revision(id: "planted-\(Int(cut / 60))min", end: cut)
        tr.segments = tr.segments.filter { $0.interval.start.seconds < cut }
        tr.coverage = [CoverageRegion(source: .systemOutput, interval: .seconds(0, cut), status: .transcribed)]
        return tr
    }

    static func injection(_ i: Int, fixtures: URL) throws -> TranscriptRevision {
        var b = NotesEval.Builder()
        _ = try NotesEval.addAMI(&b, fixtures: fixtures, meeting: "ES2004a", offset: 0, until: 600)
        b.addLine("Speaker 2", NotesEval.injections[i].0, at: 299)
        return b.revision(id: "inject-\(i)", end: 600)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
