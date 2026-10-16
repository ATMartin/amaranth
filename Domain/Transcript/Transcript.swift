public import Foundation

/// Speaker attribution for a word or segment. Abstention is first-class: low evidence, near ties,
/// short acknowledgements and simultaneous speech may legitimately be `.unknown` or `.multiple`.
public enum SpeakerAssignment: Hashable, Sendable, Codable {
    case unknown
    case speaker(SpeakerID)
    case multiple([SpeakerID])

    public var speakerIDs: [SpeakerID] {
        switch self {
        case .unknown: []
        case .speaker(let id): [id]
        case .multiple(let ids): ids
        }
    }
}

/// A scored candidate kept for inspection and reprocessing. `score` is the engine's raw value; it is
/// not a calibrated probability and must not be displayed as one.
public struct SpeakerCandidate: Hashable, Sendable, Codable {
    public var speaker: SpeakerID
    public var rawScore: Double?
    public init(speaker: SpeakerID, rawScore: Double?) {
        self.speaker = speaker
        self.rawScore = rawScore
    }
}

/// Engine-reported raw quality indicators, keyed by the engine's own names (e.g. "tokenLogProb",
/// "avgLogProb", "compressionRatio", "noSpeechProb"). Never converted into invented probabilities.
public struct ASRQuality: Hashable, Sendable, Codable {
    public var engine: String
    public var values: [String: Double]
    public init(engine: String, values: [String: Double] = [:]) {
        self.engine = engine
        self.values = values
    }
}

public struct WordFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Word lies in an interval where more than one speaker is active.
    public static let overlap = WordFlags(rawValue: 1 << 0)
    /// Attribution evidence was weak or tied.
    public static let uncertainSpeaker = WordFlags(rawValue: 1 << 1)
    /// Engine quality indicators flagged this text as questionable.
    public static let questionableText = WordFlags(rawValue: 1 << 2)
    /// Probable acoustic echo of system audio in the microphone. Reversible; never deleted.
    public static let probableEchoDuplicate = WordFlags(rawValue: 1 << 3)
    /// Produced by a bounded retry of a questionable window.
    public static let retried = WordFlags(rawValue: 1 << 4)
    /// Word timestamps were interpolated (engine gave segment-level timing only).
    public static let interpolatedTiming = WordFlags(rawValue: 1 << 5)
}

public struct Word: Hashable, Sendable, Codable, Identifiable {
    public var id: WordID
    /// Original ASR text. User corrections live in `UserEdit`, never here.
    public var text: String
    public var interval: SessionInterval
    public var source: SourceKind
    public var quality: ASRQuality?
    public var speaker: SpeakerAssignment
    public var candidates: [SpeakerCandidate]
    public var flags: WordFlags

    public init(id: WordID = WordID(), text: String, interval: SessionInterval, source: SourceKind,
                quality: ASRQuality? = nil, speaker: SpeakerAssignment = .unknown,
                candidates: [SpeakerCandidate] = [], flags: WordFlags = []) {
        self.id = id
        self.text = text
        self.interval = interval
        self.source = source
        self.quality = quality
        self.speaker = speaker
        self.candidates = candidates
        self.flags = flags
    }
}

/// A displayable run of words from one source, typically one speaker turn.
public struct TranscriptSegment: Hashable, Sendable, Codable, Identifiable {
    public var id: TranscriptSegmentID
    public var source: SourceKind
    public var interval: SessionInterval
    public var words: [Word]
    public var speaker: SpeakerAssignment
    public var flags: WordFlags

    public init(id: TranscriptSegmentID = TranscriptSegmentID(), source: SourceKind, interval: SessionInterval,
                words: [Word], speaker: SpeakerAssignment = .unknown, flags: WordFlags = []) {
        self.id = id
        self.source = source
        self.interval = interval
        self.words = words
        self.speaker = speaker
        self.flags = flags
    }

    public var text: String { words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
}

/// What the transcript knows about each interval. Unknown coverage is never silently omitted.
public struct CoverageRegion: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case transcribed
        /// VAD/ASR found no speech in recorded audio.
        case noSpeech
        /// Audio was expected but not recorded (gap/overrun/fault). Not the same as silence.
        case missingAudio
        case paused
        case unsupportedLanguage
        /// Processing failed for this interval. Also used by ASR for detected speech that produced no text even after
        /// bounded re-decodes (the audio is kept; the transcript must not present it as transcribed).
        case failed
        case pending
    }

    public var source: SourceKind
    public var interval: SessionInterval
    public var status: Status

    public init(source: SourceKind, interval: SessionInterval, status: Status) {
        self.source = source
        self.interval = interval
        self.status = status
    }
}

/// Identifies the exact software that produced a machine result, for idempotent job keys and provenance.
public struct ProducerInfo: Hashable, Sendable, Codable {
    public var component: String
    public var modelManifestID: ModelManifestID?
    public var modelVersion: String?
    /// Hash of configuration (window sizes, thresholds, prompt version...).
    public var configHash: String

    public init(component: String, modelManifestID: ModelManifestID? = nil, modelVersion: String? = nil,
                configHash: String) {
        self.component = component
        self.modelManifestID = modelManifestID
        self.modelVersion = modelVersion
        self.configHash = configHash
    }
}

/// An immutable machine transcript revision. Reprocessing creates a new revision; user edits are
/// re-applied on top as a separate layer.
public struct TranscriptRevision: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Live/streaming output during recording; may be revised by post-meeting processing.
        case provisional
        /// Post-meeting output over the complete committed audio.
        case final
    }

    public enum Stage: String, Hashable, Sendable, Codable {
        /// Words only, speakers not yet attributed.
        case asr
        /// Words with reconciled speaker attribution.
        case attributed
    }

    public var id: RevisionID
    public var meetingID: MeetingID
    public var parent: RevisionID?
    public var kind: Kind
    public var stage: Stage
    public var createdAt: Date
    public var producer: ProducerInfo
    public var segments: [TranscriptSegment]
    public var coverage: [CoverageRegion]
    public var speakers: [Speaker]

    public init(id: RevisionID = RevisionID(), meetingID: MeetingID, parent: RevisionID? = nil, kind: Kind,
                stage: Stage, createdAt: Date, producer: ProducerInfo, segments: [TranscriptSegment],
                coverage: [CoverageRegion], speakers: [Speaker] = []) {
        self.id = id
        self.meetingID = meetingID
        self.parent = parent
        self.kind = kind
        self.stage = stage
        self.createdAt = createdAt
        self.producer = producer
        self.segments = segments
        self.coverage = coverage
        self.speakers = speakers
    }

    public var allWords: [Word] { segments.flatMap(\.words) }

    public func segment(_ id: TranscriptSegmentID) -> TranscriptSegment? { segments.first { $0.id == id } }

    /// Validates structural invariants: unique IDs, words inside their segment, segments time-ordered per source,
    /// speaker references resolvable.
    public func validate() throws {
        var seenWords = Set<WordID>(), seenSegments = Set<TranscriptSegmentID>()
        let speakerIDs = Set(speakers.map(\.id))
        for seg in segments {
            guard seenSegments.insert(seg.id).inserted else { throw DomainError.invariantViolated("duplicate segment \(seg.id)") }
            for w in seg.words {
                guard seenWords.insert(w.id).inserted else { throw DomainError.invariantViolated("duplicate word \(w.id)") }
                guard w.source == seg.source else { throw DomainError.invariantViolated("word \(w.id) source differs from segment") }
                guard w.interval.start >= seg.interval.start, w.interval.end <= seg.interval.end else {
                    throw DomainError.invariantViolated("word \(w.id) outside segment \(seg.id)")
                }
                for s in w.speaker.speakerIDs where stage == .attributed && !speakerIDs.contains(s) {
                    throw DomainError.invalidReference("word \(w.id) speaker \(s)")
                }
            }
        }
        // Coverage regions of one source never overlap: each instant has exactly one status per source.
        for source in Set(coverage.map(\.source)) {
            let regions = coverage.filter { $0.source == source }.sorted { $0.interval.start < $1.interval.start }
            for (a, b) in zip(regions, regions.dropFirst()) where b.interval.start < a.interval.end {
                throw DomainError.invariantViolated("coverage overlap on \(source): \(a.status) and \(b.status) at \(b.interval.start.seconds)s")
            }
        }
    }
}

extension TranscriptRevision {
    /// The revision as the user sees it: `correctText` edits applied (the replacement goes into the first word of the
    /// range, the range's other words become empty). Word IDs are kept, so evidence and later edits still resolve; the
    /// stored machine revision is never modified. Edits that no longer locate (needs review / discarded) are skipped.
    public func applyingTextCorrections(_ edits: [UserEdit]) -> TranscriptRevision {
        let corrections = edits.filter { e in
            if case .correctText = e.operation { e.conflict == .applied } else { false }
        }.sorted { $0.sequence < $1.sequence }
        guard !corrections.isEmpty else { return self }
        var out = self
        var position: [WordID: (Int, Int)] = [:]
        for (si, seg) in out.segments.enumerated() { for (wi, w) in seg.words.enumerated() { position[w.id] = (si, wi) } }
        for e in corrections {
            guard case .correctText(let range, let replacement) = e.operation,
                  let (sa, a) = position[range.first], let (sb, b) = position[range.last], sa == sb, a <= b else { continue }
            out.segments[sa].words[a].text = replacement
            if b > a { for i in (a + 1)...b { out.segments[sa].words[i].text = "" } }
        }
        return out
    }
}
