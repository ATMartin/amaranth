import CoreML
import FluidAudio
public import Foundation
public import Domain
public import ASR

/// Full-meeting offline diarization (FluidAudio Community-1 + WeSpeaker + VBx) with meeting-wide speaker identities.
///
/// Up to `fullFileLimit` of audio is diarized in one pass. Longer meetings are diarized in `blockSeconds` blocks so
/// clustering memory stays bounded; each block's clusters are linked to meeting-wide clusters by cosine similarity of
/// their centroid embeddings (one-to-one per block, Hungarian), so identities stay consistent across blocks.
public final class FluidDiarizer: @unchecked Sendable {
    public struct Options: Sendable {
        public var maxSpeakers: Int = 8
        public var fullFileLimit: Double = 3600
        public var blockSeconds: Double = 1800
        /// Minimum centroid cosine similarity to link a block cluster to an existing meeting-wide cluster.
        public var linkThreshold: Float = 0.5
        /// FluidAudio trims overlapping speech by default; the plan requires retaining overlap, so it is kept.
        public var retainOverlap: Bool = true
        public init() {}
    }

    private let manager: OfflineDiarizerManager
    private let models: OfflineDiarizerModels
    private let config: OfflineDiarizerConfig
    public let producer: ProducerInfo
    public let options: Options

    /// `directory` is the resolved `speaker-diarization-coreml` manifest root. Built by hand from the `.mlmodelc` files:
    /// never through ModelHub/prepareModels (which can delete the model directory after a failed load).
    public init(directory: URL, manifestID: ModelManifestID, revision: String, options: Options = Options()) throws {
        ModelHub.offlineMode = true
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let c = MLModelConfiguration()
            c.computeUnits = units
            return try MLModel(contentsOf: directory.appending(path: "\(name).mlmodelc"), configuration: c)
        }
        let models = OfflineDiarizerModels(segmentationModel: try model("Segmentation", .all), fbankModel: try model("FBank", .cpuOnly),
                                           embeddingModel: try model("Embedding", .all), pldaRhoModel: try model("PldaRho", .all),
                                           pldaPsi: try Self.loadPsi(directory.appending(path: "plda-parameters.json")), compilationDuration: 0)
        var config = OfflineDiarizerConfig.default.withSpeakers(min: nil, max: options.maxSpeakers)
        config.exclusiveSegments = !options.retainOverlap
        manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        self.models = models
        self.config = config
        self.options = options
        producer = ProducerInfo(component: "fluidaudio-0.17.7/community-1-vbx", modelManifestID: manifestID, modelVersion: revision,
                                configHash: "diar-v1:overlap\(options.retainOverlap):max\(options.maxSpeakers):full\(Int(options.fullFileLimit)):block\(Int(options.blockSeconds)):link\(options.linkThreshold)")
    }

    static func loadPsi(_ url: URL) throws -> [Double] {
        struct File: Decodable { struct T: Decodable { let data_base64: String; let dtype: String }; let tensors: [String: T] }
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard let psi = f.tensors["psi"], psi.dtype == "float32",
              let raw = Data(base64Encoded: psi.data_base64, options: .ignoreUnknownCharacters), raw.count % 4 == 0, !raw.isEmpty
        else { throw CocoaError(.fileReadCorruptFile) }
        return raw.withUnsafeBytes { b in (0..<raw.count / 4).map { Double(b.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)) } }
    }

    struct RawTurn { var start: Double; var end: Double; var cluster: String }

    /// Diarizes one source's analysis audio (session-timeline aligned, so times are session seconds).
    /// `tick` is called every few seconds while an engine call is within its time budget (liveness for the worker's
    /// hang watchdog); cancellation stops a call at FluidAudio's next internal checkpoint.
    public func analyze(meetingID: MeetingID, source: SourceKind, audio: AnalysisAudio,
                        cancellation: CancellationToken, tick: @escaping @Sendable () -> Void = {}) async throws -> Domain.DiarizationResult {
        let total = audio.duration.seconds
        var turns: [RawTurn] = []
        if total <= options.fullFileLimit {
            do {
                let url = audio.url
                let r = try await Perf.measure("diarize.engine") {
                    try await EngineCall.run(cancellation: cancellation, budget: EngineCall.budget(audioSeconds: total), tick: tick) {
                        try await self.manager.process(url)
                    }
                }
                Self.record(r.timings)
                Perf.note("diarize.path", "full-file")
                turns = r.segments.map { RawTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), cluster: "c\($0.speakerId)") }
            } catch OfflineDiarizationError.noSpeechDetected {
                turns = [] // silence/music/no speech: zero speakers is the correct answer
            }
        } else {
            Perf.note("diarize.path", "blockwise")
            turns = try await blockwise(audio: audio, total: total, cancellation: cancellation, tick: tick)
        }
        return Self.result(meetingID: meetingID, source: source, producer: producer, turns: turns)
    }

    func blockwise(audio: AnalysisAudio, total: Double, cancellation: CancellationToken, tick: @escaping @Sendable () -> Void = {}) async throws -> [RawTurn] {
        var global: [(id: String, centroid: [Float], weight: Float)] = []
        var out: [RawTurn] = []
        var start = 0.0
        while start < total {
            try cancellation.check()
            let end = min(total, start + options.blockSeconds)
            let samples = try Perf.measure("diarize.read") { try audio.read(SessionInterval(unchecked: .seconds(start), .seconds(end))) }
            guard let r = try await Perf.measure("diarize.engine", {
                try await EngineCall.run(cancellation: cancellation, budget: EngineCall.budget(audioSeconds: end - start), tick: tick,
                                         { try await self.runBlock(samples) })
            }) else { start = end; continue } // no speech in this block
            Self.record(r.timings)
            // Block centroids: prefer the engine's speaker database; otherwise duration-weighted mean of segment embeddings.
            var centroids: [String: ([Float], Float)] = [:]
            if let db = r.speakerDatabase { for (k, v) in db { centroids[k] = (v, 1) } }
            for s in r.segments where centroids[s.speakerId] == nil || r.speakerDatabase == nil {
                let w = s.endTimeSeconds - s.startTimeSeconds
                var (c, cw) = centroids[s.speakerId] ?? ([Float](repeating: 0, count: s.embedding.count), 0)
                if c.count == s.embedding.count { for i in c.indices { c[i] += s.embedding[i] * w }; cw += w }
                centroids[s.speakerId] = (c, cw)
            }
            let blockIDs = centroids.keys.sorted()
            // Similarity matrix block × global; one-to-one assignment above threshold.
            var sim = [[Double]](repeating: [Double](repeating: 0, count: max(global.count, 1)), count: blockIDs.count)
            for (i, b) in blockIDs.enumerated() {
                for (j, g) in global.enumerated() { sim[i][j] = Double(Self.cosine(centroids[b]!.0, g.centroid)) }
            }
            var mapping: [String: String] = [:]
            if !global.isEmpty {
                for (i, j) in LinkAssignment.maximize(sim) where sim[i][j] >= Double(options.linkThreshold) {
                    mapping[blockIDs[i]] = global[j].id
                }
            }
            for b in blockIDs {
                let (c, w) = centroids[b]!
                if let g = mapping[b], let gi = global.firstIndex(where: { $0.id == g }) {
                    // Running weighted centroid update.
                    let tw = global[gi].weight + max(w, 1e-3)
                    global[gi].centroid = zip(global[gi].centroid, c).map { ($0 * global[gi].weight + $1 * max(w, 1e-3)) / tw }
                    global[gi].weight = tw
                } else {
                    let id = "g\(global.count)"
                    global.append((id, c, max(w, 1e-3)))
                    mapping[b] = id
                }
            }
            out += r.segments.map { RawTurn(start: Double($0.startTimeSeconds) + start, end: Double($0.endTimeSeconds) + start, cluster: mapping[$0.speakerId]!) }
            start = end
        }
        return out
    }

    /// The fields of FluidAudio's result that linking needs (its type name collides with Domain's).
    struct BlockResult {
        struct Segment { let speakerId: String; let embedding: [Float]; let startTimeSeconds: Float; let endTimeSeconds: Float }
        let segments: [Segment]
        let speakerDatabase: [String: [Float]]?
        let timings: PipelineTimings?
    }

    /// FluidAudio's own sub-stage timings (T16): the engine is a dependency, so these are its numbers, not ours.
    static func record(_ t: PipelineTimings?) {
        guard let t else { return }
        Perf.add("diarize.engine.audioLoading", seconds: t.audioLoadingSeconds)
        Perf.add("diarize.engine.segmentation", seconds: t.segmentationSeconds)
        Perf.add("diarize.engine.embeddings", seconds: t.embeddingExtractionSeconds)
        Perf.add("diarize.engine.clustering", seconds: t.speakerClusteringSeconds)
        Perf.add("diarize.engine.postProcessing", seconds: t.postProcessingSeconds)
    }

    func runBlock(_ samples: [Float]) async throws -> BlockResult? {
        // A fresh manager per block (models reused) isolates per-block state. Block mode keeps peak footprint flat with
        // meeting length (measured: 1.10 GiB at 2 h, 1.08 GiB at 4 h; full-file grows 1.18 → 1.27 GiB).
        let config = self.config, models = self.models
        let work = Task.detached(priority: .userInitiated) { () -> BlockResult? in
            let blockManager = OfflineDiarizerManager(config: config)
            blockManager.initialize(models: models)
            do {
                let r = try await blockManager.process(audio: samples)
                return BlockResult(segments: r.segments.map { .init(speakerId: $0.speakerId, embedding: $0.embedding,
                                                                     startTimeSeconds: $0.startTimeSeconds, endTimeSeconds: $0.endTimeSeconds) },
                                   speakerDatabase: r.speakerDatabase, timings: r.timings)
            } catch OfflineDiarizationError.noSpeechDetected {
                return nil
            }
        }
        // A detached task does not inherit cancellation: forward it.
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func result(meetingID: MeetingID, source: SourceKind, producer: ProducerInfo, turns raw: [RawTurn]) -> Domain.DiarizationResult {
        let ordered = raw.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        // Cluster IDs in order of first appearance, so labels are stable and readable.
        var ids: [String: ClusterID] = [:]
        for t in ordered where ids[t.cluster] == nil { ids[t.cluster] = ClusterID("\(source.rawValue)-\(ids.count)") }
        let turns = ordered.map { SpeakerTurn(interval: .seconds($0.start, $0.end), source: source, cluster: ids[$0.cluster]!) }
        return Domain.DiarizationResult(meetingID: meetingID, source: source, producer: producer,
                                 clusters: ids.values.sorted(), turns: turns, overlaps: overlaps(turns))
    }

    /// Intervals where two or more clusters are active simultaneously.
    static func overlaps(_ turns: [SpeakerTurn]) -> [SessionInterval] {
        var edges: [(SessionTime, Int)] = []
        for t in turns { edges.append((t.interval.start, 1)); edges.append((t.interval.end, -1)) }
        edges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var active = 0, start: SessionTime?
        var out: [SessionInterval] = []
        for (t, d) in edges {
            let before = active
            active += d
            if before < 2 && active >= 2 { start = t }
            if before >= 2 && active < 2, let s = start, t > s { out.append(SessionInterval(unchecked: s, t)); start = nil }
        }
        return out
    }
}

/// Small Hungarian (maximize) for block↔meeting cluster linking.
enum LinkAssignment {
    static func maximize(_ w: [[Double]]) -> [(Int, Int)] {
        let rows = w.count, cols = w.first?.count ?? 0
        guard rows > 0, cols > 0 else { return [] }
        let n = max(rows, cols)
        let maxW = (w.flatMap { $0 }.max() ?? 0) + 1
        var cost = [[Double]](repeating: [Double](repeating: maxW, count: n), count: n)
        for i in 0..<rows { for j in 0..<cols { cost[i][j] = maxW - w[i][j] } }
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n { if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta } }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var out: [(Int, Int)] = []
        for j in 1...n where p[j] - 1 < rows && j - 1 < cols { out.append((p[j] - 1, j - 1)) }
        return out
    }
}

/// Estimates how much later system-output audio reappears in the microphone (speaker bleed), by cross-correlating
/// 10 ms energy envelopes over 0–500 ms lags. Returns nil when there is no consistent echo (e.g. headphones).
public enum EchoAnalyzer {
    public static func estimateDelay(mic: AnalysisAudio, system: AnalysisAudio, maxSeconds: Double = 600) throws -> Double? {
        let n = min(mic.sampleCount, system.sampleCount, Int(maxSeconds) * AnalysisAudio.sampleRate)
        guard n > AnalysisAudio.sampleRate * 5 else { return nil }
        func envelope(_ a: AnalysisAudio) throws -> [Float] {
            var env: [Float] = []
            var i = 0
            while i < n {
                let x = try a.read(from: i, count: min(160 * 1000, n - i))
                for b in stride(from: 0, to: x.count, by: 160) {
                    let s = x[b..<min(x.count, b + 160)]
                    env.append(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
                }
                i += 160 * 1000
            }
            // Log-compressed, mean-removed.
            let l = env.map { log10($0 + 1e-8) }
            let m = l.reduce(0, +) / Float(l.count)
            return l.map { $0 - m }
        }
        let e1 = try envelope(system), e2 = try envelope(mic)
        var best = (lag: 0, score: Float(-1))
        for lag in 0...50 { // 0–500 ms in 10 ms steps
            var dot: Float = 0, a2: Float = 0, b2: Float = 0
            for i in 0..<(e1.count - lag) { dot += e1[i] * e2[i + lag]; a2 += e1[i] * e1[i]; b2 += e2[i + lag] * e2[i + lag] }
            let corr = a2 > 0 && b2 > 0 ? dot / (a2.squareRoot() * b2.squareRoot()) : 0
            if corr > best.score { best = (lag, corr) }
        }
        return best.score > 0.5 ? Double(best.lag) * 0.01 : nil
    }
}

/// Runs one long engine call so that (a) a `CancellationToken` stops it promptly (FluidAudio checks Swift task
/// cancellation inside its segmentation/embedding loops) and (b) liveness ticks flow to the worker's hang watchdog while
/// the call is within `budget` seconds. Past the budget the ticks stop, so a genuinely hung call is still detected.
public enum EngineCall {
    /// Time budget for diarizing `audioSeconds`: 10% of real time (the M2 Max runs at about 0.6%), at least 2 minutes.
    public static func budget(audioSeconds: Double) -> Double { max(120, audioSeconds * 0.1) }

    public static func run<T: Sendable>(cancellation: CancellationToken, budget: Double, tickEvery: Double = 5,
                                        tick: @escaping @Sendable () -> Void,
                                        _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try cancellation.check()
        let work = Task { try await op() }
        let start = ContinuousClock.now
        let monitor = Task {
            var last = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if cancellation.isCancelled { work.cancel(); return }
                let now = ContinuousClock.now
                if now - start < .seconds(budget), now - last >= .seconds(tickEvery) { tick(); last = now }
            }
        }
        defer { monitor.cancel() }
        let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try cancellation.check()
        return value
    }
}
