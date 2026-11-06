public import Foundation
public import Domain
public import Storage

/// What contextual retrieval needs from local models (T114). The app implements it with the XPC worker, the benchmark
/// in process. Both calls must honor cancellation of the surrounding task.
public protocol ContextualModels: Sendable {
    func plan(requestID: String, question: String, history: [AnswerTurn]) async throws -> PlanResponse
    /// Query vectors (foreground), in order.
    func embedQueries(requestID: String, texts: [String]) async throws -> EmbedResponse
    func cancel(requestID: String)
}

/// The evidence one contextual attempt found, plus everything the answer and the UI need to be honest about it.
public struct ContextualEvidence: Sendable {
    /// Ranked best first (`rank` 0…); the answer prompt orders them chronologically.
    public var passages: [RankedPassage]
    public var plan: QueryPlan
    public var planFallback: Bool
    public var constraints: ResolvedConstraints
    public var coverage: IndexCoverage
    /// Semantic retrieval ran (encoder present and query vectors computed); false → keyword only, labeled.
    public var semantic: Bool
    /// Meetings (in scope) whose generation this evidence was read at; recheck before prompting and delivery.
    public var generations: [MeetingID: Int64]
    public var timings: [String: Double]
    public var scopeMeetings: Int
    public init(passages: [RankedPassage], plan: QueryPlan, planFallback: Bool, constraints: ResolvedConstraints, coverage: IndexCoverage, semantic: Bool,
                generations: [MeetingID: Int64], timings: [String: Double], scopeMeetings: Int) {
        self.passages = passages; self.plan = plan; self.planFallback = planFallback; self.constraints = constraints; self.coverage = coverage
        self.semantic = semantic; self.generations = generations; self.timings = timings; self.scopeMeetings = scopeMeetings
    }
}

public struct RankedPassage: Sendable, Hashable {
    public var passage: Passage
    public var rank: Int
    /// Lines in it spoken by a person the question asks about (shown speaker match).
    public var askedSpeakerLines: Int
    public init(passage: Passage, rank: Int, askedSpeakerLines: Int) { self.passage = passage; self.rank = rank; self.askedSpeakerLines = askedSpeakerLines }
}

/// Spec 0010 contextual retrieval (T114): a fixed, bounded workflow — not an agent.
/// 1. Embed the question and plan it in parallel (planning has its own budget; on timeout the deterministic fallback).
/// 2. Resolve dates/people deterministically; intersect the UI scope with the date range *before* any candidate.
/// 3. Candidate lists: exact vector search per query vector (question, plan paraphrases, subquestions; ≤ 100 each) and
///    the FTS retriever over the question + literal terms, restricted to the same meeting set.
/// 4. Reciprocal rank fusion (k = 60) over chunks and notes lines; bounded deterministic rerank (asked speaker's lines,
///    literal term hits); ≤ 60 fused candidates.
/// 5. Context expansion from current index rows (±2 lines), overlapping passages merged; one extra round for
///    subquestions with no evidence in the top set; ≤ 12 passages.
public final class ContextualRetriever: Sendable {
    public let store: MeetingStore
    public let models: any ContextualModels
    /// The producer whose vectors are searched (from the indexer); nil → keyword only.
    public let producer: EncoderProducer?
    public let accountName: String?

    public init(store: MeetingStore, models: any ContextualModels, producer: EncoderProducer?, accountName: String? = nil) {
        self.store = store; self.models = models; self.producer = producer; self.accountName = accountName
    }

    public enum Failure: Error, Sendable { case deadline, cancelled }

    struct Key: Hashable { var meeting: MeetingID; var kind: Int; var ref: String }   // kind 0 = chunk ordinal, 1 = notes ref

    public func retrieve(_ request: ContextualRequest, previous: ResolvedConstraints?, requestID: String, planDeadline: Date) async throws -> ContextualEvidence {
        var timings: [String: Double] = [:]
        let t0 = ContinuousClock.now
        let tz = TimeZone(identifier: request.timeZoneIdentifier) ?? .current
        var base = ContextFilter()
        switch request.scope {
        case .all: break
        case .meeting(let m): base.meetings = [m]
        case .folder(let f): base.folder = f
        }
        // Plan and embed the question concurrently.
        let models = self.models
        let semanticOn = producer != nil
        // A follow-up (“which of those are locked in?”) also searches with the question it follows, so its subject is
        // never lost even if planning fails.
        let followUpText = request.history.last.map { $0.question + " " + request.question }
        let firstTexts = [request.question] + (followUpText.map { [$0] } ?? [])
        async let questionVectors: [[Float]] = semanticOn ? ((try? await models.embedQueries(requestID: requestID + "-q", texts: firstTexts).unpacked()) ?? []) : []
        let planned: PlanResponse = await withTaskGroup(of: PlanResponse?.self) { g in
            g.addTask { try? await models.plan(requestID: requestID + "-plan", question: request.question, history: request.history) }
            g.addTask {
                let wait = planDeadline.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                return nil
            }
            let first = await g.next() ?? nil
            g.cancelAll()
            if first == nil { models.cancel(requestID: requestID + "-plan") }
            return first ?? PlanResponse(plan: QueryPlanner_fallback(request), fallback: true, seconds: Perf.seconds(since: t0), generatedTokens: 0)
        }
        try Task.checkCancellation()
        timings["plan"] = planned.seconds
        let plan = planned.plan
        let qvs = await questionVectors
        timings["embedQuestion"] = Perf.seconds(since: t0)

        // Constraints → filter (dates before candidates).
        let tr = ContinuousClock.now
        var filter = base
        // Dates first (deterministic), then people against the meetings actually searched.
        let dated = ConstraintResolver.resolve(question: request.question, plan: plan, now: request.requestTime, timeZone: tz, previous: previous,
                                               directory: NameDirectory(speakers: [:], attendees: [:], meetingsInScope: []), accountName: accountName, mentioned: { _ in false })
        if let r = dated.dateRange { filter.start = r.start; filter.end = r.end }
        let scopeDir = try store.nameDirectory(filter)
        let peopleFilter = filter
        let constraints = ConstraintResolver.resolve(question: request.question, plan: plan, now: request.requestTime, timeZone: tz, previous: previous,
                                                     directory: scopeDir, accountName: accountName,
                                                     mentioned: { [store] in (try? store.mentions($0, filter: peopleFilter)) ?? false })
        let meetings = try store.contextMeetings(filter)
        let generations = try store.contextGenerations(meetings)
        let coverage = try store.contextCoverage(filter, producer: producer?.id)

        // Query vectors for paraphrases and subquestions (one foreground batch).
        let extraTexts = Array((plan.semanticQueries + plan.subquestions).prefix(ContextualLimits.maxSemanticQueries + ContextualLimits.maxSubquestions - 1))
        var vectors: [(String, [Float])] = []
        vectors += zip(firstTexts, qvs).map { ($0, $1) }
        if semanticOn, !extraTexts.isEmpty, let e = try? await models.embedQueries(requestID: requestID + "-x", texts: extraTexts) {
            vectors += zip(extraTexts, e.unpacked()).map { ($0, $1) }
        }
        try Task.checkCancellation()
        timings["embedPlan"] = Perf.seconds(since: tr)

        // Candidate lists.
        let tc = ContinuousClock.now
        var lists: [[Key]] = []
        var subLists: [String: [Key]] = [:]
        if let producer, !meetings.isEmpty {
            for (text, v) in vectors {
                let hits = try store.vectorSearch(v, producer: producer, filter: filter, k: ContextualLimits.candidatesPerList)
                let keys = hits.map { Key(meeting: $0.meetingID, kind: 0, ref: String($0.ordinal)) }
                lists.append(keys)
                if plan.subquestions.contains(text) { subLists[text] = keys }
            }
        }
        timings["vector"] = Perf.seconds(since: tc)
        let tf = ContinuousClock.now
        let ftsQuery = ([followUpText ?? request.question] + plan.literalTerms).joined(separator: " ")
        let fts = meetings.isEmpty ? [] : try Retriever(store: store, k: 40).search(ftsQuery, meetings: meetings)
        // Lexical passages → the chunks holding their matched lines (keeps one unit for fusion); notes lines stay notes.
        var ftsKeys: [Key] = []
        var notesPassages: [Key: Passage] = [:]
        var chunkCache: [MeetingID: [StoredChunk]] = [:]
        func chunks(_ m: MeetingID) throws -> [StoredChunk] {
            if let c = chunkCache[m] { return c }
            let c = try store.contextChunks(m); chunkCache[m] = c; return c
        }
        var ftsMatched: [Key: Set<TranscriptSegmentID>] = [:]
        for p in fts {
            if p.source != .transcript {
                let k = Key(meeting: p.meetingID, kind: 1, ref: p.ref); ftsKeys.append(k); notesPassages[k] = p; continue
            }
            let matched = Set(p.lines.filter(\.matched).compactMap(\.segmentID))
            for c in try chunks(p.meetingID) where c.spans.contains(where: { matched.contains($0.segmentID) }) {
                let k = Key(meeting: p.meetingID, kind: 0, ref: String(c.ordinal))
                if !ftsKeys.contains(k) { ftsKeys.append(k) }
                ftsMatched[k, default: []].formUnion(matched)
            }
        }
        lists.append(ftsKeys)
        timings["fts"] = Perf.seconds(since: tf)

        // Fuse.
        var score: [Key: Double] = [:]
        // The lexical list counts as much as half of all semantic lists together, so exact names and terms aren't
        // outvoted by several paraphrase vectors agreeing on generic text.
        let lexicalWeight = max(1, Double(lists.count - 1) * Self.tuning.lexicalShare)
        for (li, list) in lists.enumerated() {
            let w = li == lists.count - 1 ? lexicalWeight : 1
            for (r, k) in list.prefix(ContextualLimits.candidatesPerList).enumerated() { score[k, default: 0] += w / (ContextualLimits.rrfK + Double(r + 1)) }
        }
        // Bounded deterministic rerank: lines by an asked speaker (or the user's mapped speaker) and literal terms.
        let askedSpeakers = Set(constraints.people.filter { $0.role == .speaker && ($0.resolution == .speaker || $0.resolution == .ambiguous) }
            .flatMap(\.speakerNames).map { $0.lowercased() })
        let selfNames = constraints.people.contains { $0.role == .selfUser } ? Set(constraints.selfSpeakers.values.map { $0.lowercased() }) : []
        let terms = Set(plan.literalTerms.map { $0.lowercased() })
        var speakerLines: [Key: Int] = [:]
        // Weak singletons: seen in only one list and not near its top (0 = off).
        if Self.tuning.singletonRank > 0 {
            var seen: [Key: (lists: Int, best: Int)] = [:]
            for list in lists { for (r, k) in list.prefix(ContextualLimits.candidatesPerList).enumerated() { let v = seen[k] ?? (0, Int.max); seen[k] = (v.lists + 1, min(v.best, r)) } }
            for (k, v) in seen where v.lists == 1 && v.best >= Self.tuning.singletonRank && !ftsKeys.contains(k) { score[k] = nil }
        }
        let pool = score.sorted { $0.value != $1.value ? $0.value > $1.value : ($0.key.meeting.rawValue, $0.key.ref) < ($1.key.meeting.rawValue, $1.key.ref) }
            .prefix(ContextualLimits.fusedCandidates)
        // Names of people asked about (not the user): a chunk that names them is likely relevant even when it isn't theirs.
        let namedPeople = Set(constraints.people.filter { $0.role != .selfUser && $0.resolution != .unknown }
            .map { $0.name.lowercased() }.filter { $0.count > 1 })
        // Meeting-level evidence: the sum of a meeting's best three candidate scores. Relevant meetings tend to hit
        // several times; one loosely similar chunk from an unrelated meeting doesn't.
        var perMeeting: [MeetingID: [Double]] = [:]
        for (k, s) in pool { perMeeting[k.meeting, default: []].append(s) }
        let meetingScore = perMeeting.mapValues { $0.sorted(by: >).prefix(3).reduce(0, +) }
        var reranked: [(Key, Double)] = []
        for (k, s) in pool {
            var boost = 1.0
            if k.kind == 0, let c = try chunks(k.meeting).first(where: { String($0.ordinal) == k.ref }) {
                let lines = c.text.split(separator: "\n").map { $0.lowercased() }.filter { !$0.hasPrefix("meeting: ") }
                let bySpeaker = lines.filter { l in (askedSpeakers.union(selfNames)).contains { l.hasPrefix($0 + ":") || l.hasPrefix($0 + ",") } }.count
                speakerLines[k] = bySpeaker
                if bySpeaker > 0 { boost += 0.35 }
                let lower = c.text.lowercased()
                if !namedPeople.isEmpty, namedPeople.contains(where: { Self.containsWord(lower, $0) }) { boost += Self.tuning.nameBoost }
                if !terms.isEmpty, terms.contains(where: { Self.containsWord(lower, $0) }) { boost += 0.15 }
            }
            reranked.append((k, s * boost + Self.tuning.meetingWeight * (meetingScore[k.meeting] ?? 0)))
        }
        reranked.sort { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.meeting.rawValue, $0.0.ref) < ($1.0.meeting.rawValue, $1.0.ref) }
        var chosen = Array(reranked.prefix(ContextualLimits.finalPassages).map(\.0))
        // Extra round (one): a subquestion with nothing in the chosen set gets its best two chunks.
        if ContextualLimits.extraRetrievalRounds > 0 {
            for (_, keys) in subLists where !keys.contains(where: chosen.contains) {
                for k in keys.prefix(2) where !chosen.contains(k) { chosen.append(k) }
            }
            if chosen.count > ContextualLimits.finalPassages + 4 { chosen = Array(chosen.prefix(ContextualLimits.finalPassages + 4)) }
        }

        // Expand into passages from current rows.
        let te = ContinuousClock.now
        let meta = try store.meetingMeta(Set(chosen.map(\.meeting)))
        var out: [RankedPassage] = []
        var usedLines: [MeetingID: Set<TranscriptSegmentID>] = [:]
        for (rank, k) in chosen.enumerated() {
            guard let m = meta[k.meeting] else { continue }
            if k.kind == 1, let p = notesPassages[k] {
                out.append(RankedPassage(passage: p, rank: rank, askedSpeakerLines: 0)); continue
            }
            guard let c = try chunks(k.meeting).first(where: { String($0.ordinal) == k.ref }) else { continue }
            let segs = c.spans.map(\.segmentID)
            let (lines, evidence) = try store.transcriptWindow(k.meeting, segments: segs, context: ContextualLimits.contextLines)
            guard !lines.isEmpty else { continue }
            // Merge with an earlier passage of the same meeting that overlaps.
            let ids = Set(lines.compactMap(\.segmentID))
            if let i = out.firstIndex(where: { $0.passage.meetingID == k.meeting && $0.passage.source == .transcript && !ids.isDisjoint(with: Set($0.passage.lines.compactMap(\.segmentID))) }) {
                var p = out[i].passage
                let have = Set(p.lines.compactMap(\.segmentID))
                let merged = (p.lines + lines.filter { !have.contains($0.segmentID!) }).sorted { ($0.start?.nanoseconds ?? 0) < ($1.start?.nanoseconds ?? 0) }
                if merged.count <= 30 {
                    p.lines = merged; p.evidence = Array(Set(p.evidence + evidence)).sorted { $0.segmentID.rawValue < $1.segmentID.rawValue }
                    out[i].passage = p; out[i].askedSpeakerLines += speakerLines[k] ?? 0
                    continue
                }
            }
            usedLines[k.meeting, default: []].formUnion(ids)
            let matched = ftsMatched[k] ?? Set(segs)
            let marked = lines.map { l -> Passage.Line in var l = l; l.matched = l.segmentID.map(matched.contains) ?? false; return l }
            out.append(RankedPassage(passage: Passage(meetingID: k.meeting, meetingTitle: m.title, meetingDate: m.start, source: .transcript, ref: segs.first?.rawValue ?? "",
                                                      lines: marked, evidence: evidence, score: score[k] ?? 0),
                                     rank: rank, askedSpeakerLines: speakerLines[k] ?? 0))
        }
        timings["expand"] = Perf.seconds(since: te)
        timings["retrieval"] = Perf.seconds(since: tr)
        return ContextualEvidence(passages: out, plan: plan, planFallback: planned.fallback, constraints: constraints, coverage: coverage,
                                  semantic: semanticOn && !vectors.isEmpty, generations: generations, timings: timings, scopeMeetings: meetings.count)
    }

    /// Rerank weights, frozen from the dev-set sweep (t114-retrieval.md): the lexical list weighs as much as all semantic
    /// lists together; +0.35 for lines by an asked speaker and for chunks naming an asked person; meeting aggregation and
    /// singleton filtering measured no gain and are off.
    struct Tuning { var meetingWeight: Double; var nameBoost: Double; var lexicalShare: Double; var singletonRank: Int }
    static let tuning = Tuning(meetingWeight: 0, nameBoost: 0.35, lexicalShare: 1, singletonRank: 0)

    static func containsWord(_ haystack: String, _ word: String) -> Bool {
        var from = haystack.startIndex
        while let r = haystack.range(of: word, range: from..<haystack.endIndex) {
            let before = r.lowerBound == haystack.startIndex || !haystack[haystack.index(before: r.lowerBound)].isLetter
            let after = r.upperBound == haystack.endIndex || !haystack[r.upperBound].isLetter
            if before && after { return true }
            from = r.upperBound
        }
        return false
    }

    /// The constrained plan without a model (mirrors `QueryPlanner.fallback`, which lives with the model code).
    func QueryPlanner_fallback(_ r: ContextualRequest) -> QueryPlan {
        let words = r.question.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        var people: [QueryPlan.Person] = []
        for (i, w) in words.enumerated() where i > 0 && w.first?.isUppercase == true && w.count > 1 { people.append(.init(name: w, role: .mentioned)) }
        return QueryPlan(people: people).validated(question: r.question, context: r.history.map(\.question).joined(separator: " "))
    }
}
