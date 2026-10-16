public import Foundation
import Synchronization

/// Cooperative cancellation shared across a job's stages and the XPC cancel message.
public final class CancellationToken: Sendable {
    private let flag = Atomic<Bool>(false)
    public init() {}
    public func cancel() { flag.store(true, ordering: .releasing) }
    public var isCancelled: Bool { flag.load(ordering: .acquiring) }
    public func check() throws { if isCancelled { throw CancellationError() } }
}

/// A slice of prepared (16 kHz mono) analysis audio for one source, mapped onto the session timeline.
/// Carries file references, never in-memory PCM for a whole meeting.
public struct AudioSlice: Hashable, Sendable, Codable {
    public var meetingID: MeetingID
    public var source: SourceKind
    public var interval: SessionInterval
    /// Analysis-derivative file holding at least `interval`.
    public var fileURL: URL
    /// Session time of frame 0 of `fileURL`.
    public var fileSessionStart: SessionTime
    public var format: AudioFormat

    public init(meetingID: MeetingID, source: SourceKind, interval: SessionInterval, fileURL: URL,
                fileSessionStart: SessionTime, format: AudioFormat = .analysis) {
        self.meetingID = meetingID
        self.source = source
        self.interval = interval
        self.fileURL = fileURL
        self.fileSessionStart = fileSessionStart
        self.format = format
    }
}

public struct TranscriptionContext: Hashable, Sendable, Codable {
    public var languageCode: String
    /// Bounded tail of preceding text for continuity across windows.
    public var precedingText: String
    public var vocabularyHints: [String]
    public init(languageCode: String = "en", precedingText: String = "", vocabularyHints: [String] = []) {
        self.languageCode = languageCode
        self.precedingText = precedingText
        self.vocabularyHints = vocabularyHints
    }
}

public struct TimedWord: Hashable, Sendable, Codable {
    public var text: String
    public var interval: SessionInterval
    public var quality: ASRQuality?
    public var interpolatedTiming: Bool
    public init(text: String, interval: SessionInterval, quality: ASRQuality? = nil, interpolatedTiming: Bool = false) {
        self.text = text
        self.interval = interval
        self.quality = quality
        self.interpolatedTiming = interpolatedTiming
    }
}

public struct TranscriptionChunkResult: Hashable, Sendable, Codable {
    public var slice: AudioSlice
    public var words: [TimedWord]
    /// e.g. detected language, hallucination-loop detector hits, retry count, real-time factor.
    public var diagnostics: [String: String]
    public init(slice: AudioSlice, words: [TimedWord], diagnostics: [String: String] = [:]) {
        self.slice = slice
        self.words = words
        self.diagnostics = diagnostics
    }
}

public protocol Transcriber: Sendable {
    var producer: ProducerInfo { get }
    func transcribe(_ slice: AudioSlice, context: TranscriptionContext,
                    cancellation: CancellationToken) async throws -> TranscriptionChunkResult
}

/// Full-meeting input for one source; implementations read from disk in bounded windows.
public struct DiarizationInput: Hashable, Sendable, Codable {
    public var meetingID: MeetingID
    public var source: SourceKind
    public var slices: [AudioSlice]
    public init(meetingID: MeetingID, source: SourceKind, slices: [AudioSlice]) {
        self.meetingID = meetingID
        self.source = source
        self.slices = slices
    }
}

public protocol Diarizer: Sendable {
    var producer: ProducerInfo { get }
    func analyze(_ input: DiarizationInput, constraints: DiarizationConstraints,
                 cancellation: CancellationToken) async throws -> DiarizationResult
}

/// Maps each source's derivative timeline onto the session timeline; also carries capture events so
/// reconciliation can mark missing coverage.
public struct SourceMap: Hashable, Sendable, Codable {
    public var epochs: [CaptureEpoch]
    public var events: [CaptureEvent]
    public init(epochs: [CaptureEpoch], events: [CaptureEvent]) {
        self.epochs = epochs
        self.events = events
    }
}

public struct ReconciliationResult: Hashable, Sendable, Codable {
    public var revision: TranscriptRevision
    /// Edits whose rebase was ambiguous; surfaced for review rather than overwritten.
    public var editsNeedingReview: [UserEdit]
    public init(revision: TranscriptRevision, editsNeedingReview: [UserEdit]) {
        self.revision = revision
        self.editsNeedingReview = editsNeedingReview
    }
}

public protocol Reconciler: Sendable {
    func combine(_ transcript: TranscriptRevision, diarization: [DiarizationResult], sourceMap: SourceMap,
                 edits: [UserEdit]) throws -> ReconciliationResult
}

/// Immutable input to note generation: a committed transcript revision plus applied edits.
public struct SummaryInputSnapshot: Hashable, Sendable, Codable {
    public var transcript: TranscriptRevision
    public var edits: [UserEdit]
    /// Present only when the user explicitly opted to include personal notes.
    public var scratchpad: ScratchpadRevision?
    public init(transcript: TranscriptRevision, edits: [UserEdit], scratchpad: ScratchpadRevision?) {
        self.transcript = transcript
        self.edits = edits
        self.scratchpad = scratchpad?.includeInSummary == true ? scratchpad : nil
    }
}

public struct SummaryTemplate: Hashable, Sendable, Codable {
    public var id: String
    public var promptVersion: String
    public init(id: String = "default", promptVersion: String) {
        self.id = id
        self.promptVersion = promptVersion
    }
}

public protocol Summarizer: Sendable {
    var producer: ProducerInfo { get }
    func generate(_ snapshot: SummaryInputSnapshot, template: SummaryTemplate,
                  cancellation: CancellationToken) async throws -> SummaryRevision
}
