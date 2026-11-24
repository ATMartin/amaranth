public import Foundation
import Domain

/// What the transcription stage may take from incremental processing (T19). Reuse never changes the transcript:
/// - the incremental derivative is compared byte by byte with the prepared one; only its identical prefix counts;
/// - a VAD chunk is reused if it is the same chunk and lies inside that prefix;
/// - a window result is reused if the planned window is identical (span, contexts, VAD speech) and every sample a
///   decode or re-decode of it may read lies inside that prefix.
public final class IncrementalReuse: @unchecked Sendable {
    static let windowsDirectory = "windows"
    static func derivativeName(_ s: SourceKind) -> String { "\(s.rawValue)-16k.wav" }
    static func stateName(_ s: SourceKind) -> String { "\(s.rawValue)-state.json" }
    static func chunkName(_ s: SourceKind, _ chunk: (Double, Double)) -> String {
        "vad-\(s.rawValue)-\(chunk.0.bitPattern)-\(chunk.1.bitPattern).json"
    }

    struct SourceState: Codable { var settledSamples: Int }
    struct Chunk: Codable { var start: Double; var end: Double; var samples: Int; var speech: [[Double]] }

    let directory: URL
    let policy: TranscriptionPipeline.WindowPolicy
    private let lock = NSLock()
    /// Samples of each source's incremental derivative identical to the prepared derivative.
    private var identical: [SourceKind: Int] = [:]
    /// Windows and VAD chunks taken from incremental processing (tests, diagnostics).
    private(set) var reusedWindows = 0, reusedChunks = 0

    public init(directory: URL, policy: TranscriptionPipeline.WindowPolicy) {
        self.directory = directory
        self.policy = policy
    }

    static func saveChunk(_ speech: [(Double, Double)], source: SourceKind, chunk: (Double, Double), samples: Int, in directory: URL) throws {
        try ContractCoding.encode(Chunk(start: chunk.0, end: chunk.1, samples: samples, speech: speech.map { [$0.0, $0.1] }))
            .write(to: directory.appending(path: chunkName(source, chunk)), options: .atomic)
    }

    /// Finds how many leading samples of the incremental derivative equal the prepared derivative `audio`.
    func validate(_ source: SourceKind, against audio: AnalysisAudio) throws {
        guard let d = try? Data(contentsOf: directory.appending(path: Self.stateName(source))),
              let state = try? ContractCoding.decode(SourceState.self, from: d),
              let mine = FileHandle(forReadingAtPath: directory.appending(path: Self.derivativeName(source)).path),
              let theirs = FileHandle(forReadingAtPath: audio.url.path) else { return }
        defer { try? mine.close(); try? theirs.close() }
        try mine.seek(toOffset: AnalysisAudio.headerSize)
        try theirs.seek(toOffset: AnalysisAudio.headerSize)
        var same = 0
        let block = 1 << 20
        while same < state.settledSamples {
            let n = min(block, state.settledSamples - same)
            guard let a = try mine.read(upToCount: n * 2), let b = try theirs.read(upToCount: n * 2) else { break }
            if a == b, a.count == n * 2 { same += n; continue }
            // First differing sample in this block.
            let k = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            same += k / 2
            break
        }
        lock.withLock { identical[source] = same }
        Perf.add("asr.reuse.identicalSeconds", seconds: Double(same) / Double(AnalysisAudio.sampleRate), count: 0)
    }

    private func identicalSamples(_ source: SourceKind) -> Int { lock.withLock { identical[source] ?? 0 } }

    /// Speech of VAD chunk `chunk` if incremental processing completed the same chunk over identical audio.
    func speech(_ source: SourceKind, chunk: (Double, Double)) -> [(Double, Double)]? {
        guard let d = try? Data(contentsOf: directory.appending(path: Self.chunkName(source, chunk))),
              let c = try? ContractCoding.decode(Chunk.self, from: d), c.start == chunk.0, c.end == chunk.1,
              AnalysisAudio.sampleIndex(.seconds(chunk.1)) <= identicalSamples(source) else { return nil }
        lock.withLock { reusedChunks += 1 }
        return c.speech.map { ($0[0], $0[1]) }
    }

    /// The incremental result for window `w` if it is the same window over identical audio.
    func window(_ w: TranscriptionPipeline.Window, source: SourceKind) -> TranscriptionPipeline.WindowResult? {
        // Decodes read at most `maxInput` beyond the window's end (the first pass reads its right context; re-decodes
        // stay within the single-pass budget).
        guard AnalysisAudio.sampleIndex(.seconds(w.end + policy.maxInput)) <= identicalSamples(source),
              let d = try? Data(contentsOf: directory.appending(path: Self.windowsDirectory)
                .appending(path: TranscriptionPipeline.checkpointName(w, source: source, policy: policy))),
              let r = try? ContractCoding.decode(TranscriptionPipeline.WindowResult.self, from: d), r.window == w else { return nil }
        lock.withLock { reusedWindows += 1 }
        return r
    }
}
