public import Foundation
public import Domain

/// Final-quality transcription while a meeting is still recording (T19, docs/milestone-e-performance-plan.md).
///
/// Runs the batch pipeline's own steps over the audio committed so far, so that at Stop only the tail is left:
/// - the 16 kHz derivative is built with `AnalysisPreparer.DerivativeBuilder`, segment by segment;
/// - VAD runs over the same 600 s chunk grid, fed block by block (`SileroVAD.Stream`, identical probabilities);
/// - windows come from `TranscriptionPipeline.plan`, which stops at the first decision later audio could change;
/// - each window is decoded by `TranscriptionPipeline.transcribe` (same contexts, under-yield guard and checkpoint).
///
/// Nothing here is published. At Stop the transcription stage plans the whole meeting again and reuses a window only if
/// the window is identical and the audio it may read is byte-identical (`IncrementalReuse`), so the final transcript
/// is exactly the batch transcript. Live text shows the decoded windows as they finish.
public final class IncrementalTranscriber: @unchecked Sendable {
    public struct Progress: Sendable {
        public struct Source: Sendable {
            public var source: SourceKind
            /// Highest segment sequence appended to the derivative (nil: none yet).
            public var lastSequence: Int64?
            /// Audio settled in the derivative, VAD-final speech, and the end of the contiguous decoded windows.
            public var settledUntil: Double
            public var speechSettledUntil: Double
            public var finalizedUntil: Double
            public var plannedWindows: Int
            public var decodedWindows: Int
            /// Words of windows that joined the decoded prefix in this call (session seconds).
            public var newWords: [ParakeetASR.Word]
        }
        public var sources: [Source]
        /// Windows transcribed in this call (decoded, or loaded from an earlier worker's checkpoint).
        public var decoded: Int
    }

    let meetingDirectory: URL
    let directory: URL
    let pipeline: TranscriptionPipeline
    let decoder: ParakeetASR
    let vad: SileroVAD
    private let lock = NSLock()
    private var busy = false
    private var sources: [SourceKind: SourceState] = [:]

    /// `directory` is the meeting's incremental work directory (`IncrementalReuse` reads it at Stop).
    public init(meetingDirectory: URL, directory: URL, decoder: ParakeetASR, vad: SileroVAD,
                policy: TranscriptionPipeline.WindowPolicy = .default) throws {
        self.meetingDirectory = meetingDirectory
        self.directory = directory
        self.decoder = decoder
        self.vad = vad
        let windows = directory.appending(path: IncrementalReuse.windowsDirectory)
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        pipeline = TranscriptionPipeline(decoders: [decoder], vads: [vad], workDirectory: windows, policy: policy)
    }

    final class SourceState {
        let kind: SourceKind
        let builder: AnalysisPreparer.DerivativeBuilder
        let audio: AnalysisAudio
        var segments: [AudioSegmentRecord] = []
        var pending: [Int64: AudioSegmentRecord] = [:]
        var chunks: [Chunk] = []
        var windows: [TranscriptionPipeline.Window] = []
        var results: [Int: TranscriptionPipeline.WindowResult] = [:]
        var reportedPrefix = 0
        var speechSettledUntil = 0.0

        struct Chunk {
            var start: Double
            var end: Double          // .infinity while the chunk is still open
            var stream = SileroVAD.Stream()
            var speech: [(Double, Double)]?   // set once the chunk is complete
            var partial: [(Double, Double)] = []
        }

        init(kind: SourceKind, meetingDirectory: URL, directory: URL) throws {
            self.kind = kind
            let url = directory.appending(path: IncrementalReuse.derivativeName(kind))
            builder = try AnalysisPreparer.DerivativeBuilder(meetingDirectory: meetingDirectory, url: url)
            audio = AnalysisAudio(url: url)
        }

        /// Samples of the derivative no later segment can change (with half a second of margin for clock-drift overlap).
        var settledSamples: Int { segments.isEmpty ? 0 : max(0, builder.lastPlacedIndex - AnalysisAudio.sampleRate / 2) }
    }

    /// Appends newly committed segments, advances VAD and the window plan, and decodes windows until `deadline`.
    /// Segments may repeat or arrive in any order; each source's segments are appended in sequence order without gaps.
    /// Returns nil if another call is in progress.
    public func advance(segments: [AudioSegmentRecord], events: [CaptureEvent], deadline: ContinuousClock.Instant,
                        cancellation: CancellationToken) async throws -> Progress? {
        guard lock.withLock({ () -> Bool in defer { busy = true }; return !busy }) else { return nil }
        defer { lock.withLock { busy = false } }
        for seg in segments where seg.state == .committed {
            let s = try state(seg.source)
            if let last = s.segments.last?.sequence, seg.sequence <= last { continue }
            s.pending[seg.sequence] = seg
        }
        var states = sources.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        for s in states {
            try Perf.measure("incremental.place") { try place(s) }
            try await Perf.measure("incremental.vad") { try await runVAD(s, events: events, cancellation: cancellation) }
            Perf.measure("incremental.plan") { plan(s, events: events) }
        }
        // Decode the earliest pending window across sources until the deadline.
        var decoded = 0
        while ContinuousClock.now < deadline {
            try cancellation.check()
            states = sources.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
            let next = states.compactMap { s -> (SourceState, TranscriptionPipeline.Window)? in
                let limit = Double(s.settledSamples) / Double(AnalysisAudio.sampleRate)
                return s.windows.first { s.results[$0.index]?.window != $0 && $0.end + pipeline.maxWindow <= limit }.map { (s, $0) }
            }.min { $0.1.start < $1.1.start }
            guard let (s, w) = next else { break }
            s.results[w.index] = try await pipeline.transcribe(w, source: s.kind, audio: s.audio, engine: decoder)
            decoded += 1
        }
        return Progress(sources: states.map { s in
            var prefix = s.reportedPrefix
            prefix = min(prefix, s.windows.count)
            while prefix < s.windows.count, s.results[s.windows[prefix].index]?.window == s.windows[prefix] { prefix += 1 }
            let words = s.windows[s.reportedPrefix..<prefix].flatMap { s.results[$0.index]?.words ?? [] }
            s.reportedPrefix = prefix
            return Progress.Source(source: s.kind, lastSequence: s.segments.last?.sequence,
                                   settledUntil: Double(s.settledSamples) / Double(AnalysisAudio.sampleRate),
                                   speechSettledUntil: s.speechSettledUntil, finalizedUntil: prefix > 0 ? s.windows[prefix - 1].end : 0,
                                   plannedWindows: s.windows.count, decodedWindows: s.results.count, newWords: words)
        }, decoded: decoded)
    }

    private func state(_ kind: SourceKind) throws -> SourceState {
        if let s = sources[kind] { return s }
        let s = try SourceState(kind: kind, meetingDirectory: meetingDirectory, directory: directory)
        sources[kind] = s
        return s
    }

    /// Appends pending segments that continue the sequence, then records how much of the derivative is settled.
    /// Segments commit in order, so a hole that persists while several later segments are waiting is a segment that
    /// will never commit (the prepare stage skips it too).
    private func place(_ s: SourceState) throws {
        while true {
            let next: AudioSegmentRecord?
            if let last = s.segments.last {
                next = s.pending[last.sequence + 1] ?? (s.pending.count >= 3 ? s.pending.min { $0.key < $1.key }?.value : nil)
            } else {
                next = s.pending.min { $0.key < $1.key }?.value
            }
            guard let next else { break }
            s.pending[next.sequence] = nil
            try s.builder.append(next)
            s.segments.append(next)
        }
        try ContractCoding.encode(IncrementalReuse.SourceState(settledSamples: s.settledSamples))
            .write(to: directory.appending(path: IncrementalReuse.stateName(s.kind)), options: .atomic)
    }

    /// Recorded regions so far; the last one is open (`.infinity`) while it reaches the newest segment.
    private func regions(_ s: SourceState, events: [CaptureEvent]) -> [(Double, Double)] {
        guard let last = s.segments.last else { return [] }
        let end = last.interval.end
        return AnalysisPreparer.coverage(source: s.kind, segments: s.segments, events: events, end: end).filter { $0.status == .transcribed }
            .map { ($0.interval.start.seconds, $0.interval.end == end ? .infinity : $0.interval.end.seconds) }
    }

    /// Feeds settled audio to each chunk's VAD stream; a chunk whose end is settled is completed and saved for reuse.
    private func runVAD(_ s: SourceState, events: [CaptureEvent], cancellation: CancellationToken) async throws {
        let settled = s.settledSamples
        let available = Double(settled) / Double(AnalysisAudio.sampleRate)
        for (t, e) in TranscriptionPipeline.vadChunks(regions(s, events: events), available: available) {
            try cancellation.check()
            let i = s.chunks.firstIndex { $0.start == t } ?? { s.chunks.append(.init(start: t, end: e)); return s.chunks.count - 1 }()
            if s.chunks[i].speech != nil { continue }
            s.chunks[i].end = e
            let a = AnalysisAudio.sampleIndex(.seconds(t))
            let b = e.isFinite ? AnalysisAudio.sampleIndex(.seconds(e)) : Int.max
            let fed = a + s.chunks[i].stream.samples
            if e.isFinite, b <= settled {
                // Complete: the rest, including a final partial block.
                if b > fed { try await vad.feed(&s.chunks[i].stream, try s.audio.read(from: fed, count: b - fed)) }
                let speech = await vad.speech(s.chunks[i].stream, padding: TranscriptionPipeline.contextPadding, maxSegment: 14).map { ($0.0 + t, $0.1 + t) }
                s.chunks[i].speech = speech
                try IncrementalReuse.saveChunk(speech, source: s.kind, chunk: (t, e), samples: b - a, in: directory)
            } else {
                let blocks = (min(settled, b) - fed) / SileroVAD.blockSize
                guard blocks > 0 else { continue }
                try await vad.feed(&s.chunks[i].stream, try s.audio.read(from: fed, count: blocks * SileroVAD.blockSize))
                s.chunks[i].partial = await vad.speech(s.chunks[i].stream, padding: TranscriptionPipeline.contextPadding, maxSegment: 14).map { ($0.0 + t, $0.1 + t) }
            }
        }
    }

    /// Speech settles about 16 s behind the newest VAD block: the segmenter splits speech longer than 14 s at an
    /// earlier pause, and pads a segment's end according to the gap that follows.
    static let speechLookahead = 16.0

    /// Plans every window whose decision can no longer change.
    private func plan(_ s: SourceState, events: [CaptureEvent]) {
        let regions = regions(s, events: events)
        // Speech is settled up to the earliest unfinished chunk's newest block, less the segmenter's lookahead.
        var speech: [(Double, Double)] = []
        var horizon = Double.infinity
        for (t, _) in TranscriptionPipeline.vadChunks(regions, available: Double(s.settledSamples) / Double(AnalysisAudio.sampleRate)) {
            guard let c = s.chunks.first(where: { $0.start == t }) else { horizon = min(horizon, t - Self.speechLookahead); continue }
            if let sp = c.speech { speech += sp; continue }
            speech += c.partial
            horizon = min(horizon, t + Double(c.stream.samples) / Double(AnalysisAudio.sampleRate) - Self.speechLookahead)
        }
        let merged = TranscriptionPipeline.merge(speech.compactMap { $0.0 < horizon ? ($0.0, min($0.1, horizon)) : nil })
        // Nothing is known after the horizon, so the next cut lies at or after the middle of the silence that reaches it:
        // decisions that only look at earlier cuts are final.
        let bound = horizon.isFinite ? ((merged.last?.1).map { ($0 + horizon) / 2 } ?? horizon) : .infinity
        s.speechSettledUntil = horizon
        s.windows = TranscriptionPipeline.plan(regions: regions, merged: merged, policy: pipeline.policy, settledUntil: bound)
    }
}
