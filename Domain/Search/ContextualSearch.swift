public import Foundation

// Contextual search contracts (spec 0010, frozen in T109). Typed, versioned and bounded: everything a local model
// proposes passes through these types and `validated(...)` before it can reach retrieval, and every limit the workflow
// relies on is a named constant here rather than a literal in the orchestrator.

/// Executable limits of one contextual Ask attempt (spec 0010 "Recommended architecture", frozen in T109). Changing one
/// needs benchmark evidence recorded in docs/qualification/milestone-v/.
public enum ContextualLimits {
    /// Contract version of the plan/chunk/encoder/outcome types below; bump on any incompatible change.
    public static let version = "ctx-v1"

    // Input
    public static let maxQuestionCharacters = 500
    /// Earlier turns of the session used as follow-up context (never as evidence).
    public static let maxHistoryTurns = 3
    public static let maxHistoryAnswerCharacters = 600

    // Plan
    public static let maxSubquestions = 3
    /// Semantic query variants in total, the original question included.
    public static let maxSemanticQueries = 3
    public static let maxLiteralTerms = 8
    public static let maxPeople = 4
    public static let maxPlanStringCharacters = 160
    /// Tokens the planner may generate (grammar-constrained JSON).
    public static let plannerMaxTokens = 200

    // Retrieval
    /// Candidates kept after rank fusion (FTS + vectors) and before context expansion.
    public static let fusedCandidates = 60
    /// FTS rows / vector hits read per query variant before fusion.
    public static let candidatesPerList = 100
    /// Passages that may reach the answer prompt.
    public static let finalPassages = 12
    /// Additional retrieval rounds for a missing piece (subquestion without evidence).
    public static let extraRetrievalRounds = 1
    /// Reciprocal rank fusion constant (score = Σ 1 / (k + rank)).
    public static let rrfK = 60.0
    /// Transcript lines of context added on each side of a retrieved chunk's best lines.
    public static let contextLines = 2

    // Answer
    /// Prompt tokens of the answer call (N's measured budget; changing it needs benchmark evidence).
    public static let answerPromptBudget = 2200
    public static let answerMaxTokens = 320

    // Time (seconds)
    /// One foreground attempt, from submission to a checked answer or explicit terminal state on screen; includes
    /// queueing, cold model loads, planning, every retrieval round, generation, checking and UI delivery. Never reset.
    public static let deadline: Double = 15
    /// Work stops this long before the deadline so cleanup and delivery fit inside it.
    public static let deliveryMargin: Double = 0.75
    /// Visible loading feedback after submission.
    public static let feedbackWithin: Double = 0.25
    /// Cancellation acknowledged (animation stopped, state shown) within.
    public static let cancelAcknowledgedWithin: Double = 1
    /// Planning gets at most this long; after it the constrained fallback plan is used (labeled).
    public static let planningBudget: Double = 4.5

    // Chunking (encoder input)
    /// Target and hard limits of one chunk, in encoder tokens; the storage layer estimates with `estimatedTokens` and
    /// the encoder re-checks with its tokenizer. T110 measured the spec's initial 200–400 against smaller chunks on the
    /// dev set at an equal 100-line evidence budget (docs/decisions/models/0003-search-encoder.md): 120/200 gave the best
    /// hybrid + date recall (33/41 vs 30/41), with 1.6× the vectors of 300/400.
    public static let chunkTargetTokens = 120
    public static let chunkMinTokens = 60
    public static let chunkMaxTokens = 200
    /// Lines repeated from the previous chunk of the same meeting.
    public static let chunkOverlapLines = 1

    /// Rough tokens of English text (≈ 1.33 tokens per word, + 2 per line for speaker labels and separators).
    public static func estimatedTokens(words: Int, lines: Int) -> Int { (words * 4 + 2) / 3 + 2 * lines }
}

// MARK: - Query plan (model output, validated)

/// What the local planner proposes for a question (T113). Only data: no SQL, tools, paths or scope. `validated`
/// clamps sizes, drops what is not grounded in the question, and never widens the explicit UI scope.
public struct QueryPlan: Hashable, Sendable, Codable {
    public enum PersonRole: String, Hashable, Sendable, Codable {
        /// Said something (“what did Andrew propose”).
        case speaker
        /// Talked about (“who can staff it”, “what was said about Andrew”).
        case mentioned
        /// The user themself (I/my/me).
        case selfUser = "self"
    }
    public struct Person: Hashable, Sendable, Codable {
        public var name: String
        public var role: PersonRole
        public init(name: String, role: PersonRole) { self.name = name; self.role = role }
    }
    public enum Intent: String, Hashable, Sendable, Codable {
        case fact, decisionStatus = "decision_status", commitments, staffing, proposal, summary, list, comparison, other
    }

    /// Paraphrases of the information need for semantic search (the original question is always searched too).
    public var semanticQueries: [String]
    /// Words or names to match literally (FTS).
    public var literalTerms: [String]
    public var people: [Person]
    /// The phrase of the question that constrains *when the meeting happened* (“last week”, “today”), copied from the
    /// question; nil when no meeting-date constraint. Dates that are the topic (“planning for 2027”) are not this.
    public var meetingTime: String?
    public var subquestions: [String]
    public var intent: Intent
    /// “every”, “never”, exact counts, full timelines: needs bounded enumeration with coverage, not top-k.
    public var exhaustive: Bool

    public init(semanticQueries: [String] = [], literalTerms: [String] = [], people: [Person] = [], meetingTime: String? = nil,
                subquestions: [String] = [], intent: Intent = .other, exhaustive: Bool = false) {
        self.semanticQueries = semanticQueries; self.literalTerms = literalTerms; self.people = people; self.meetingTime = meetingTime
        self.subquestions = subquestions; self.intent = intent; self.exhaustive = exhaustive
    }

    /// Limits applied, empty strings dropped, strings truncated, `meetingTime` kept only if it occurs in `question`
    /// (case-insensitive) and people only if their name occurs in the question or the follow-up context.
    public func validated(question: String, context: String = "") -> QueryPlan {
        func clean(_ s: String) -> String? {
            let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(ContextualLimits.maxPlanStringCharacters))
        }
        func unique(_ xs: [String], _ n: Int) -> [String] {
            var seen = Set<String>()
            return Array(xs.compactMap(clean).filter { seen.insert($0.lowercased()).inserted }.prefix(n))
        }
        let haystack = (question + " " + context).lowercased()
        var p = self
        p.semanticQueries = unique(semanticQueries.filter { $0.lowercased() != question.lowercased() }, ContextualLimits.maxSemanticQueries - 1)
        p.literalTerms = unique(literalTerms, ContextualLimits.maxLiteralTerms)
        var seenPeople = Set<String>()
        let selfWords: Set<String> = ["i", "me", "my", "myself", "mine"]
        let groupWords: Set<String> = ["we", "us", "our", "ours", "they", "them", "everyone", "someone", "anyone", "the team", "team"]
        let questionWords = Set(question.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        var people = self.people
        // I/me/my in the question always means the user, whatever the model said.
        if !questionWords.isDisjoint(with: selfWords) { people.append(Person(name: "I", role: .selfUser)) }
        p.people = Array(people.compactMap { person -> Person? in
            guard let n = clean(person.name) else { return nil }
            let lower = n.lowercased()
            if person.role == .selfUser || selfWords.contains(lower) {
                // The user only when the question itself says I/me/my (a model can't make the question about them).
                guard !questionWords.isDisjoint(with: selfWords) else { return nil }
                return seenPeople.insert("\u{0}self").inserted ? Person(name: "I", role: .selfUser) : nil
            }
            if groupWords.contains(lower) { return nil }
            // Whole-word grounding (“Al” is not grounded by “also”).
            // Split both on every non-alphanumeric, so "Al's" and "Ask Al." ground "Al" and "O'Neil" matches itself.
            let hayWords = " " + haystack.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
            let nameWords = " " + lower.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
            guard hayWords.contains(nameWords), seenPeople.insert(lower).inserted else { return nil }
            return Person(name: n, role: person.role)
        }.prefix(ContextualLimits.maxPeople))
        p.meetingTime = meetingTime.flatMap(clean).flatMap { question.lowercased().contains($0.lowercased()) ? $0 : nil }
        p.subquestions = unique(subquestions, ContextualLimits.maxSubquestions)
        return p
    }
}

// MARK: - Resolved constraints (deterministic)

/// A meeting-start filter: inclusive start, exclusive end, as UTC instants (spec 0010: compare with
/// `clock.utcOrigin ?? createdAt`).
public struct MeetingDateRange: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case calendarWeek = "calendar_week", rolling, day, month, custom }
    public var start: Date
    public var end: Date
    public var kind: Kind
    /// The question's words this came from (“last week”).
    public var phrase: String
    public init(start: Date, end: Date, kind: Kind, phrase: String) { self.start = start; self.end = end; self.kind = kind; self.phrase = phrase }
    public func contains(_ d: Date) -> Bool { d >= start && d < end }
}

/// A person constraint after resolving names against current shown speaker names, attendees and transcript mentions.
public struct ResolvedPerson: Hashable, Sendable, Codable {
    public enum Resolution: String, Hashable, Sendable, Codable {
        /// A current shown speaker name in scope (renamed by the user or from reconciliation).
        case speaker
        /// Only mentioned in speech or attendee lists: content can be about them, but nothing proves they spoke.
        case mentionedOnly = "mentioned_only"
        /// Several different shown speakers match (“Andrew” vs “Andrew K.”): clarify or qualify.
        case ambiguous
        /// Nowhere in scope.
        case unknown
        /// I/me/my: a speaker the user renamed to “Me” (or their account name), per meeting.
        case selfMapped = "self_mapped"
        /// I/me/my with no trustworthy mapping in some or all meetings: qualify by speaker label or clarify.
        case selfUnmapped = "self_unmapped"
    }
    public var name: String
    public var role: QueryPlan.PersonRole
    public var resolution: Resolution
    /// Shown speaker names that matched (for `.speaker`/`.ambiguous`/`.selfMapped`).
    public var speakerNames: [String]
    public init(name: String, role: QueryPlan.PersonRole, resolution: Resolution, speakerNames: [String] = []) {
        self.name = name; self.role = role; self.resolution = resolution; self.speakerNames = speakerNames
    }
}

/// The frozen request: what was asked, where, when, and the follow-up context (never evidence).
public struct ContextualRequest: Hashable, Sendable, Codable {
    public enum Scope: Hashable, Sendable, Codable {
        case all
        case meeting(MeetingID)
        case folder(FolderID)
    }
    public var question: String
    public var scope: Scope
    public var requestTime: Date
    public var timeZoneIdentifier: String
    public var history: [AnswerTurn]
    public init(question: String, scope: Scope, requestTime: Date, timeZoneIdentifier: String, history: [AnswerTurn] = []) {
        self.question = String(question.prefix(ContextualLimits.maxQuestionCharacters))
        self.scope = scope; self.requestTime = requestTime; self.timeZoneIdentifier = timeZoneIdentifier
        self.history = Array(history.suffix(ContextualLimits.maxHistoryTurns)).map {
            AnswerTurn(question: String($0.question.prefix(ContextualLimits.maxQuestionCharacters)),
                       answer: String($0.answer.prefix(ContextualLimits.maxHistoryAnswerCharacters)))
        }
    }
}

// MARK: - Chunks and encoder identity

/// How current transcript text becomes encoder input (T111). Part of every chunk's identity: a change re-chunks.
public enum ChunkingVersion {
    /// chunk-v2 (T114): chunk-v1 plus a `Meeting: <title>` first line (dev-set evidence, t114-retrieval.md).
    public static let current = "chunk-v2"
}

/// Everything that changes the vector space (T110). Vectors are compatible only with the same `id`.
public struct EncoderProducer: Hashable, Sendable, Codable {
    public var family: String
    public var manifestID: String
    public var revision: String
    public var weightsSHA256: String
    public var quantization: String
    public var dimensions: Int
    public var pooling: String
    public var normalization: String
    public var queryInstruction: String
    public var documentPrefix: String
    public var chunking: String
    public var runtime: String
    public init(family: String, manifestID: String, revision: String, weightsSHA256: String, quantization: String, dimensions: Int,
                pooling: String, normalization: String, queryInstruction: String, documentPrefix: String, chunking: String, runtime: String) {
        self.family = family; self.manifestID = manifestID; self.revision = revision; self.weightsSHA256 = weightsSHA256
        self.quantization = quantization; self.dimensions = dimensions; self.pooling = pooling; self.normalization = normalization
        self.queryInstruction = queryInstruction; self.documentPrefix = documentPrefix; self.chunking = chunking; self.runtime = runtime
    }
    /// Stable short identity stored with every vector.
    public var id: String {
        let parts = [family, manifestID, revision, weightsSHA256, quantization, String(dimensions), pooling, normalization,
                     queryInstruction, documentPrefix, chunking, runtime]
        return "enc-" + StableHash.hex(parts.joined(separator: "\u{1f}")).prefix(16)
    }
}

/// FNV-1a 64-bit, for identities and content keys (not security).
public enum StableHash {
    public static func hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        var h2: UInt64 = 0x84222325cbf29ce4
        for b in s.utf8.reversed() { h2 ^= UInt64(b); h2 = h2 &* 0x100000001b3 }
        return String(format: "%016llx%016llx", h, h2)
    }
}

/// Validates a vector before it may be stored or compared: right dimension, finite, not zero, unit length.
public enum VectorCheck {
    public static func isValid(_ v: [Float], dimensions: Int) -> Bool {
        guard v.count == dimensions, v.allSatisfy(\.isFinite) else { return false }
        let n = v.reduce(0) { $0 + $1 * $1 }
        return n > 0.98 && n < 1.02
    }
}

// MARK: - Coverage, stages and outcomes

/// How much of the scope the semantic index covers right now (shown during backfill; answers carry it).
public struct IndexCoverage: Hashable, Sendable, Codable {
    public var meetingsInScope: Int
    /// Meetings whose every current chunk has a vector of the active encoder.
    public var meetingsIndexed: Int
    public var chunks: Int
    public var chunksEmbedded: Int
    /// No usable encoder (not installed, corrupt, failed): semantic search is off; keyword lookup still works.
    public var encoderAvailable: Bool
    public init(meetingsInScope: Int, meetingsIndexed: Int, chunks: Int, chunksEmbedded: Int, encoderAvailable: Bool) {
        self.meetingsInScope = meetingsInScope; self.meetingsIndexed = meetingsIndexed; self.chunks = chunks
        self.chunksEmbedded = chunksEmbedded; self.encoderAvailable = encoderAvailable
    }
    public var complete: Bool { encoderAvailable && meetingsIndexed == meetingsInScope }
}

/// Where a foreground attempt is (drives the loading copy).
public enum AskStage: String, Hashable, Sendable, Codable {
    case preparing, waitingForRecording = "waiting_for_recording", loadingModel = "loading_model", planning, searching, reading, answering
}

/// How a foreground attempt ended. Every attempt ends in exactly one of these within `ContextualLimits.deadline`.
public enum AskTerminal: String, Hashable, Sendable, Codable {
    /// A checked answer with valid current citations.
    case answered
    /// A checked answer that covers only part of the question or of the scope (labeled).
    case partial
    /// The question needs the user to choose (ambiguous person, unknown “I”).
    case clarification
    /// Searched, and the evidence found doesn't support an answer (not proof that it wasn't discussed).
    case insufficientEvidence = "insufficient_evidence"
    case timedOut = "timed_out"
    /// Models missing, worker unavailable, recording in progress.
    case unavailable
    case cancelled
    case failed
    /// The sources changed while answering; the result was suppressed.
    case stale
}
