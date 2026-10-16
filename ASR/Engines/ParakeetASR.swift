import CoreML
import FluidAudio
public import Foundation
public import Domain

/// Parakeet TDT v3 via FluidAudio, loaded strictly from a resolved local model directory (no Hub access possible).
public final class ParakeetASR: @unchecked Sendable {
    public struct Word: Codable, Sendable, Hashable {
        public var text: String
        public var start: Double
        public var end: Double
        /// Mean of the engine's raw token confidences for this word (not a calibrated probability).
        public var tokenConfidence: Double
    }

    private let manager: AsrManager
    public let loadSeconds: Double
    public let producer: ProducerInfo

    /// `directory` is the resolved `parakeet-tdt-0.6b-v3-coreml` manifest root from `LocalModelRegistry`.
    public init(directory: URL, manifestID: ModelManifestID, revision: String) throws {
        ModelHub.offlineMode = true
        let t0 = ContinuousClock.now
        let models = try AsrModels.loadLocal(from: directory, version: .v3, encoderPrecision: .int8)
        manager = AsrManager(config: .default, models: models)
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        producer = ProducerInfo(component: "fluidaudio-0.17.7/parakeet-tdt-0.6b-v3", modelManifestID: manifestID, modelVersion: revision,
                                configHash: "asr-v8:ctx2+underyield-retry+failed-coverage:single-pass14.9:enc-default")
    }

    /// Longest input accepted: one single pass inside Parakeet's 15 s window. FluidAudio 0.17.7 chunks longer inputs
    /// internally and can silently drop whole chunks (see TranscriptionPipeline), so longer inputs are refused.
    public static let maxInputSeconds = 14.9

    public enum InputError: Error { case tooLong(seconds: Double) }

    /// Transcribes 16 kHz mono samples (≤ `maxInputSeconds`); word times are relative to the first sample.
    public func transcribe(_ samples: [Float]) async throws -> [Word] {
        let seconds = Double(samples.count) / Double(AnalysisAudio.sampleRate)
        guard seconds <= Self.maxInputSeconds + 0.001 else { throw InputError.tooLong(seconds: seconds) }
        guard samples.count >= AnalysisAudio.sampleRate / 4 else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let r = try await manager.transcribe(samples, decoderState: &state)
        return Self.words(from: r.tokenTimings ?? [])
    }

    /// **Benchmark reference only — never call from production code** (a test enforces this). Long input through
    /// FluidAudio's internal chunking, which silently drops whole chunks at some lengths (asr/0001). `tailPadding`
    /// seconds of silence are appended.
    public func benchmarkOnlyTranscribeLong(_ samples: [Float], tailPadding: Double) async throws -> [Word] {
        guard samples.count >= AnalysisAudio.sampleRate / 4 else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let padded = samples + [Float](repeating: 0, count: Int(tailPadding * Double(AnalysisAudio.sampleRate)))
        let r = try await manager.transcribe(padded, decoderState: &state)
        let end = Double(samples.count) / Double(AnalysisAudio.sampleRate)
        return Self.words(from: r.tokenTimings ?? []).filter { $0.start < end }
    }

    /// Groups SentencePiece tokens into words, keeping the raw token confidences.
    static func words(from tokens: [TokenTiming]) -> [Word] {
        var out: [Word] = []
        var text = "", start = 0.0, end = 0.0, confs: [Float] = []
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(Word(text: t, start: start, end: end, tokenConfidence: Double(confs.reduce(0, +)) / Double(max(confs.count, 1)))) }
            text = ""; confs = []
        }
        for tok in tokens where !tok.token.isEmpty && tok.token != "<blank>" && tok.token != "<pad>" {
            let boundary = tok.token.hasPrefix("▁") || tok.token.hasPrefix(" ")
            if boundary || text.isEmpty {
                flush()
                text = String(tok.token.drop(while: { $0 == "▁" || $0 == " " }))
                start = tok.startTime
            } else {
                text += tok.token
            }
            end = tok.endTime
            confs.append(tok.confidence)
        }
        flush()
        return out
    }
}

/// Silero VAD via FluidAudio, from a resolved local `.mlmodelc`.
public final class SileroVAD: @unchecked Sendable {
    private let manager: VadManager

    public init(modelFile: URL) throws {
        ModelHub.offlineMode = true
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        manager = VadManager(config: .default, vadModel: try MLModel(contentsOf: modelFile, configuration: config))
    }

    /// Speech regions (seconds, relative to the first sample), padded by `padding`.
    public func speech(_ samples: [Float], padding: Double = 0.3, maxSegment: Double = 14) async throws -> [(Double, Double)] {
        guard samples.count >= 4096 else { return [] }
        let cfg = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.5, maxSpeechDuration: maxSegment,
                                        speechPadding: min(padding, 0.25))
        let segs = try await manager.segmentSpeech(samples, config: cfg)
        return segs.map { (max(0, $0.startTime - max(0, padding - 0.25)), $0.endTime + max(0, padding - 0.25)) }
    }
}
