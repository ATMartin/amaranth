import CoreML
import FluidAudio
import Foundation

/// FluidAudio Parakeet TDT, loaded strictly from a local directory with all downloads disabled.
public final class ParakeetEngine: @unchecked Sendable {
    public enum Variant: String, CaseIterable, Sendable {
        case v2 = "parakeet-v2"
        case v3 = "parakeet-v3"          // default encoder: 6-bit LUT (FluidAudio#760 risk)
        case v3int8v2 = "parakeet-v3-int8v2"
    }

    public let variant: Variant
    private let manager: AsrManager
    public let loadSeconds: Double

    public init(variant: Variant, modelStore: URL) async throws {
        ModelHub.offlineMode = true // hard guard: any accidental Hub path throws instead of downloading
        self.variant = variant
        let (dir, version, precision): (String, AsrModelVersion, ParakeetEncoderPrecision) = switch variant {
        case .v2: ("parakeet-tdt-0.6b-v2-coreml", .v2, .int8)
        case .v3: ("parakeet-tdt-0.6b-v3-coreml", .v3, .int8)
        case .v3int8v2: ("parakeet-tdt-0.6b-v3-coreml", .v3, .int8V2)
        }
        let t0 = ContinuousClock.now
        let models = try AsrModels.loadLocal(from: modelStore.appending(path: dir), version: version, encoderPrecision: precision)
        manager = AsrManager(config: .default, models: models)
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Transcribes a 16 kHz mono file. Returns words with timings relative to the file start.
    public func transcribe(_ url: URL) async throws -> (words: [BenchWord], text: String) {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let r = try await manager.transcribe(url, decoderState: &state)
        let words = buildWordTimings(from: r.tokenTimings ?? []).map {
            BenchWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime, end: $0.endTime)
        }.filter { !$0.text.isEmpty }
        return (words, r.text)
    }

    public func transcribe(samples: [Float]) async throws -> (words: [BenchWord], text: String) {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let r = try await manager.transcribe(samples, decoderState: &state)
        let words = buildWordTimings(from: r.tokenTimings ?? []).map {
            BenchWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.startTime, end: $0.endTime)
        }.filter { !$0.text.isEmpty }
        return (words, r.text)
    }
}

/// FluidAudio offline (Community-1 segmentation + embeddings + VBx) diarizer over a whole file.
public final class FluidOfflineDiarizerEngine: @unchecked Sendable {
    private let manager: OfflineDiarizerManager
    public let loadSeconds: Double

    public init(modelStore: URL, minSpeakers: Int? = nil, maxSpeakers: Int? = nil) async throws {
        ModelHub.offlineMode = true
        let t0 = ContinuousClock.now
        // Explicit local construction: no ModelHub path (it remaps folders, checks revision markers, and its
        // prepareModels() deletes the directory after a failed load). Compute units mirror FluidAudio defaults.
        let dir = modelStore.appending(path: "speaker-diarization-coreml")
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let c = MLModelConfiguration()
            c.computeUnits = units
            return try MLModel(contentsOf: dir.appending(path: "\(name).mlmodelc"), configuration: c)
        }
        let models = OfflineDiarizerModels(segmentationModel: try model("Segmentation", .all), fbankModel: try model("FBank", .cpuOnly),
                                           embeddingModel: try model("Embedding", .all), pldaRhoModel: try model("PldaRho", .all),
                                           pldaPsi: try Self.loadPsi(dir.appending(path: "plda-parameters.json")),
                                           compilationDuration: 0)
        var config = OfflineDiarizerConfig.default
        if minSpeakers != nil || maxSpeakers != nil { config = config.withSpeakers(min: minSpeakers, max: maxSpeakers) }
        manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Decodes `tensors.psi` (float32, base64) from the pinned plda-parameters.json.
    static func loadPsi(_ url: URL) throws -> [Double] {
        struct File: Decodable { struct T: Decodable { let data_base64: String; let dtype: String }; let tensors: [String: T] }
        let f = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard let psi = f.tensors["psi"], psi.dtype == "float32",
              let raw = Data(base64Encoded: psi.data_base64, options: .ignoreUnknownCharacters), raw.count % 4 == 0, !raw.isEmpty
        else { throw BenchError.model("plda psi") }
        return raw.withUnsafeBytes { b in (0..<raw.count / 4).map { Double(b.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self)) } }
    }

    public func diarize(_ url: URL) async throws -> [BenchSpeakerSegment] {
        let r = try await manager.process(url)
        return r.segments.map { BenchSpeakerSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}
