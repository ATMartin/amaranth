import Foundation
import WhisperKit

/// WhisperKit large-v3-turbo (challenger), local folders only; tokenizer passed explicitly so nothing is fetched.
public final class WhisperEngine: @unchecked Sendable {
    public enum Variant: String, CaseIterable, Sendable {
        case turbo = "whisper-turbo"
        case turbo626 = "whisper-turbo-626mb"
    }

    public let variant: Variant
    private let kit: WhisperKit
    public let loadSeconds: Double

    public init(variant: Variant, modelStore: URL) async throws {
        self.variant = variant
        let folder = variant == .turbo ? "openai_whisper-large-v3-v20240930" : "openai_whisper-large-v3-v20240930_626MB"
        let config = WhisperKitConfig(modelFolder: modelStore.appending(path: folder).path,
                                      tokenizerFolder: modelStore.appending(path: "openai-whisper-large-v3-tokenizer"),
                                      verbose: false, prewarm: true, load: true, download: false)
        let t0 = ContinuousClock.now
        kit = try await WhisperKit(config)
        let d = ContinuousClock.now - t0
        loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public func transcribe(_ url: URL) async throws -> (words: [BenchWord], text: String) {
        let options = DecodingOptions(language: "en", wordTimestamps: true, chunkingStrategy: .vad)
        let results = await kit.transcribe(audioPaths: [url.path],
                                           audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)),
                                           decodeOptions: options)
        guard let first = results.first, let rs = first else { throw BenchError.engine("whisper returned no result") }
        let words = rs.flatMap { $0.segments }.flatMap { $0.words ?? [] }.map {
            BenchWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: Double($0.start), end: Double($0.end))
        }.filter { !$0.text.isEmpty }
        return (words, rs.map(\.text).joined(separator: " "))
    }
}
