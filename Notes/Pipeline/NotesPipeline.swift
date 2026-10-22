public import Foundation
public import Domain
import CryptoKit

/// T09: evidence-backed meeting notes from a transcript revision, fully local (plan §8).
///
/// 1. **Input:** the transcript as numbered lines (`NotesInputDocument`); audio without text appears as non-citable
///    markers; the private scratchpad is included only when the user opted in, labelled as not spoken.
/// 2. **Map:** token-budgeted chunks (default 5,000 tokens with 3 lines of overlap) cover the *whole* meeting. Each chunk
///    is extracted with a grammar-constrained prompt; invalid or truncated output gets one bounded repair attempt with a
///    smaller item cap. A chunk that still fails is reported as a limitation, never skipped silently.
/// 3. **Check:** cited ids must exist in that chunk; owners and deadlines must occur in the cited passage; numbers in the
///    item must occur in the passage; items resting only on text addressed to an AI are rejected; decisions and actions
///    need spoken evidence.
/// 4. **Verify:** every decision and action, and any item the checks doubt, is re-read against its cited passage by the
///    model (yes/partly/no; decision vs proposal). "no" drops it, "partly" marks it uncertain, "proposal" demotes a
///    decision to a topic.
/// 5. **Reduce:** near-duplicates merge with their evidence unioned (never across a negation mismatch, so revised or
///    contradicting statements both survive in time order); per-kind caps keep items spread across the timeline.
/// 6. **Overview** is written from the validated items only, each sentence citing items (mapped to their evidence).
///    **Limitations** are computed, not generated.
///
/// Results are checkpointed per call, so a cancelled job resumes. Nothing here has side effects beyond the work
/// directory: transcript text can only ever become data in the returned `SummaryRevision`.
public final class NotesPipeline: @unchecked Sendable {
    public struct Options: Sendable, Hashable, Codable {
        public var chunkTokens = 5000
        public var overlapLines = 3
        public var maxItemsPerChunk = 16
        public var repairMaxItems = 8
        public var outputTokens = 1800
        public var maxVerifications = 120
        public var caps: [String: Int] = ["decision": 25, "actionItem": 30, "openQuestion": 20, "topic": 15]
        public var personalNoteTokenLimit = 1000
        public init() {}
    }

    public enum Failure: Error, Equatable { case nothingProduced(String) }

    let generator: any TextGenerator
    let workDirectory: URL
    let options: Options

    public init(generator: any TextGenerator, workDirectory: URL, options: Options = Options()) {
        self.generator = generator
        self.workDirectory = workDirectory
        self.options = options
    }

    public var configHash: String { "\(NotesPrompts.version):\(generator.identity.configHash):chunk\(options.chunkTokens)" }

    struct Candidate: Codable, Sendable {
        var kind: SummaryItemKind
        var title: String?
        var text: String
        var lines: [Int]
        var owner: String?
        var due: String?
        var uncertain: Bool
        var firstLine: Int { lines.min() ?? Int.max }
    }

    public struct Diagnostics: Codable, Sendable {
        public var chunks = 0
        public var failedChunks: [String] = []
        public var repairs = 0
        public var extracted = 0
        public var droppedInvalidEvidence = 0
        public var droppedAddressedToAI = 0
        public var droppedByVerifier = 0
        public var demotedProposals = 0
        public var removedOwners = 0
        public var removedDue = 0
        public var uncertain = 0
        public var merged = 0
        public var cappedOut = 0
        public var verifications = 0
        public var droppedOverviewSentences = 0
    }
    public private(set) var diagnostics = Diagnostics()

    public func run(meetingID: MeetingID, transcript: TranscriptRevision, editSequence: Int, scratchpad: ScratchpadRevision?,
                    cancellation: CancellationToken, progress: @Sendable (Double) -> Void = { _ in }) throws -> SummaryRevision {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        diagnostics = Diagnostics()
        let doc = NotesInputDocument.build(transcript: transcript, scratchpad: scratchpad)
        let spoken = doc.lines.filter { !$0.isPersonalNote }
        var personal = doc.lines.filter(\.isPersonalNote)
        var limitations: [String] = []
        // Personal notes ride along with every chunk (they have no time); cap their size.
        var personalTokens = 0
        personal = personal.prefix { l in personalTokens += generator.countTokens(l.text) + 12; return personalTokens <= options.personalNoteTokenLimit }
        if personal.count < doc.lines.filter(\.isPersonalNote).count {
            limitations.append("Only the first part of your included personal notes fit in the notes model's context.")
        }
        let chunks = Perf.measure("notes.chunking") { makeChunks(spoken, doc: doc, reserve: personalTokens) }
        diagnostics.chunks = chunks.count
        let lineSpeakers = Dictionary(doc.lines.map { ($0.id, $0.speaker) }, uniquingKeysWith: { a, _ in a })
        func passage(_ ids: [Int], context: Int = 0) -> String {
            var set = Set(ids)
            if context > 0 {
                for id in ids where id < NotesInputDocument.personalNoteBase {
                    for d in 1...context { set.insert(id - d); set.insert(id + d) }
                }
            }
            return doc.render(ArraySlice(set.sorted().compactMap { doc.line($0) }))
        }

        // 2. Map
        let totalUnits = Double(chunks.count) * 2 + 1
        var candidates: [Candidate] = []
        for (ci, chunk) in chunks.enumerated() {
            try cancellation.check()
            let rendered = doc.render(chunk + personal)
            let allowed = Set(chunk.map(\.id) + personal.map(\.id))
            guard let out = try Perf.measure("notes.extract", { try extract(rendered, cancellation: cancellation) }) else {
                let span = "\(NotesInputDocument.clock(chunk.first?.start ?? 0))–\(NotesInputDocument.clock(chunk.last?.start ?? 0))"
                diagnostics.failedChunks.append(span)
                limitations.append("Notes could not be generated for part of the meeting (\(span)); read the transcript for that part.")
                progress(Double(ci + 1) / totalUnits)
                continue
            }
            diagnostics.extracted += out.items.count
            for item in out.items {
                let lines = Array(Set(item.evidence.filter { allowed.contains($0) })).sorted()
                guard !lines.isEmpty, let kind = Self.kind(item.kind) else { diagnostics.droppedInvalidEvidence += 1; continue }
                candidates.append(Candidate(kind: kind, title: kind == .topic ? item.title : nil, text: item.text, lines: lines,
                                            owner: item.owner, due: item.due, uncertain: false))
            }
            progress(Double(ci + 1) / totalUnits)
        }
        guard !candidates.isEmpty || diagnostics.failedChunks.count < chunks.count || chunks.isEmpty else {
            throw Failure.nothingProduced("every chunk failed extraction")
        }

        // 3. Deterministic checks
        var checked: [(Candidate, needsVerify: Bool)] = []
        for var c in candidates {
            let spokenLines = c.lines.filter { $0 < NotesInputDocument.personalNoteBase }
            let pText = passage(c.lines)
            if !spokenLines.isEmpty, spokenLines.allSatisfy({ EvidenceChecker.looksAddressedToAI(doc.line($0)?.text ?? "") }) {
                diagnostics.droppedAddressedToAI += 1; continue
            }
            if spokenLines.isEmpty, c.kind == .decision || c.kind == .actionItem {
                c.kind = .topic; c.owner = nil; c.due = nil   // personal notes alone cannot make a decision or action
            }
            if let o = c.owner, !EvidenceChecker.ownerSupported(o, passage: pText, speakers: c.lines.compactMap { lineSpeakers[$0] }) {
                c.owner = nil; diagnostics.removedOwners += 1
            }
            if let d = c.due, !EvidenceChecker.dueSupported(d, passage: pText) { c.due = nil; diagnostics.removedDue += 1 }
            var doubt = false
            if !EvidenceChecker.unsupportedNumbers(c.text, passage: pText).isEmpty { doubt = true }
            if !EvidenceChecker.unsupportedNames(c.text, passage: pText, speakers: c.lines.compactMap { lineSpeakers[$0] }).isEmpty { doubt = true }
            if EvidenceChecker.lexicalSupport(c.text, passage: pText) < 0.2 { doubt = true }
            if EvidenceChecker.looksAddressedToAI(c.text) { doubt = true }
            if doubt { c.uncertain = true }
            checked.append((c, c.kind == .decision || c.kind == .actionItem || doubt))
        }

        // 4. Verify
        var verified: [Candidate] = []
        let toVerify = checked.filter(\.needsVerify).count
        var done = 0
        for (var c, needs) in checked {
            try cancellation.check()
            guard needs else { verified.append(c); continue }
            guard diagnostics.verifications < options.maxVerifications else { c.uncertain = true; verified.append(c); continue }
            let pText = passage(c.lines, context: 1)
            guard let v = try Perf.measure("notes.verify", { try verify(c, passage: pText, cancellation: cancellation) }) else {
                c.uncertain = true; verified.append(c); continue
            }
            diagnostics.verifications += 1
            done += 1
            progress((Double(chunks.count) + Double(done) / Double(max(1, toVerify)) * Double(chunks.count)) / totalUnits)
            switch v.supported {
            case "no": diagnostics.droppedByVerifier += 1; continue
            case "partly": c.uncertain = true
            default:
                // The verifier can clear doubt raised by lexical checks, but never an unsupported number or name.
                if EvidenceChecker.unsupportedNumbers(c.text, passage: pText).isEmpty, !EvidenceChecker.looksAddressedToAI(c.text),
                   EvidenceChecker.unsupportedNames(c.text, passage: pText, speakers: c.lines.compactMap { lineSpeakers[$0] }).isEmpty { c.uncertain = false }
            }
            if c.kind == .decision, v.kind == "proposal" || v.kind == "topic" {
                c.kind = .topic; diagnostics.demotedProposals += 1   // no made-up title: the text stands alone
            }
            // Owner/due: keep only what both the model and the passage support.
            if c.owner != nil, v.owner == nil { c.owner = nil; diagnostics.removedOwners += 1 }
            if c.due != nil, v.due == nil { c.due = nil; diagnostics.removedDue += 1 }
            verified.append(c)
        }

        // 5. Reduce
        var reduced = reduce(verified, doc: doc)
        // Ties (same first line, different kinds) need a fixed order: it is the overview prompt's order.
        reduced.sort { ($0.firstLine, $0.kind.rawValue) < ($1.firstLine, $1.kind.rawValue) }
        diagnostics.uncertain = reduced.filter(\.uncertain).count

        // 6. Overview + assemble
        try cancellation.check()
        let scratchID = (scratchpad?.includeInSummary ?? false) ? scratchpad?.id : nil
        func refs(_ lines: [Int]) -> [EvidenceRef] {
            lines.flatMap { doc.evidence($0, transcript: transcript.id, scratchpad: scratchID) }
        }
        /// Lines that name the owner or are spoken by them.
        func ownerLines(_ c: Candidate) -> [Int] {
            guard let owner = c.owner else { return [] }
            return c.lines.filter { id in
                lineSpeakers[id] == owner || EvidenceChecker.ownerSupported(owner, passage: doc.line(id)?.text ?? "", speakers: [])
            }
        }
        var items: [SummaryItem] = []
        for (n, c) in reduced.enumerated() {
            items.append(SummaryItem(id: SummaryItemID("\(c.kind.rawValue)-\(c.firstLine)-\(n)"), kind: c.kind, title: c.title, text: c.text,
                                     evidence: refs(c.lines), owner: c.owner, ownerEvidence: refs(ownerLines(c)),
                                     due: c.due.map { DueDate(originalText: $0) }, uncertain: c.uncertain))
        }
        let overview = try Perf.measure("notes.overview") { try makeOverview(reduced, refs: refs, passage: { passage($0) }, cancellation: cancellation) }
        progress(1)
        limitations += computedLimitations(transcript: transcript, doc: doc, scratchpadIncluded: scratchID != nil)
        let limitationItems = limitations.enumerated().map { SummaryItem(id: SummaryItemID("limitation-\($0.offset)"), kind: .limitation, text: $0.element, evidence: []) }
        let content = SummaryContent(overview: overview, topics: items.filter { $0.kind == .topic },
                                     decisions: items.filter { $0.kind == .decision }, actionItems: items.filter { $0.kind == .actionItem },
                                     openQuestions: items.filter { $0.kind == .openQuestion }, limitations: limitationItems)
        let dropped = diagnostics.droppedInvalidEvidence + diagnostics.droppedAddressedToAI + diagnostics.droppedByVerifier
        let report = SummaryValidationReport(status: dropped > 0 || !diagnostics.failedChunks.isEmpty || diagnostics.uncertain > 0 ? .validWithOmissions : .valid,
                                             droppedItemCount: dropped, uncertainItemCount: diagnostics.uncertain,
                                             repairAttempted: diagnostics.repairs > 0, messages: Self.messages(diagnostics))
        var producer = generator.identity
        producer.configHash = configHash
        let rev = SummaryRevision(meetingID: meetingID, transcriptRevisionID: transcript.id, editSequence: editSequence, createdAt: Date(),
                                  producer: producer, promptVersion: NotesPrompts.version, content: content, validation: report,
                                  scratchpadRevisionID: scratchID, influencedByPersonalNotes: scratchID != nil)
        try rev.validateReferences(transcript: transcript, scratchpad: scratchID == nil ? nil : scratchpad)
        return rev
    }

    // MARK: Chunking

    func makeChunks(_ lines: [NotesLine], doc: NotesInputDocument, reserve: Int) -> [ArraySlice<NotesLine>] {
        guard !lines.isEmpty else { return [] }
        let overhead = generator.countTokens(generator.chatPrompt(system: NotesPrompts.extractSystem(maxItems: options.maxItemsPerChunk),
                                                                  user: NotesPrompts.extractUser("")))
        let budget = min(options.chunkTokens, generator.contextTokens - overhead - options.outputTokens - reserve - 64)
        let cost = lines.map { generator.countTokens(doc.render([$0][...])) + 1 }
        var chunks: [ArraySlice<NotesLine>] = []
        var start = 0
        while start < lines.count {
            var end = start, used = 0
            while end < lines.count, used + cost[end] <= budget || end == start { used += cost[end]; end += 1 }
            chunks.append(lines[start..<end])
            if end >= lines.count { break }
            start = max(start + 1, end - options.overlapLines)
        }
        return chunks
    }

    // MARK: Model calls (checkpointed)

    func cached<T: Codable & Sendable>(_ key: [String], _ make: () throws -> T?) throws -> T? {
        let name = SHA256.hash(data: Data(([NotesPrompts.version, generator.identity.configHash] + key).joined(separator: "\u{1f}").utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = workDirectory.appending(path: "\(name).json")
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Box<T>.self, from: d) { return v.value }
        let v = try make()
        try JSONEncoder().encode(Box(value: v)).write(to: url, options: .atomic)
        return v
    }
    struct Box<T: Codable & Sendable>: Codable, Sendable { var value: T? }

    func extract(_ rendered: String, cancellation: CancellationToken) throws -> NotesPrompts.ExtractOutput? {
        try cached(["extract", rendered]) {
            for (attempt, cap) in [options.maxItemsPerChunk, options.repairMaxItems].enumerated() {
                if attempt > 0 { diagnostics.repairs += 1 }
                let prompt = generator.chatPrompt(system: NotesPrompts.extractSystem(maxItems: cap), user: NotesPrompts.extractUser(rendered))
                let r = try generator.generate(prompt: prompt, grammar: NotesPrompts.extractGrammar(maxItems: cap),
                                               maxTokens: options.outputTokens, cancellation: cancellation)
                if !r.hitTokenLimit, let out = try? JSONDecoder().decode(NotesPrompts.ExtractOutput.self, from: Data(r.text.utf8)) { return out }
            }
            return nil
        }
    }

    func verify(_ c: Candidate, passage: String, cancellation: CancellationToken) throws -> NotesPrompts.VerifyOutput? {
        let kind = switch c.kind { case .decision: "decision"; case .actionItem: "action"; case .openQuestion: "question"; default: "topic" }
        let user = NotesPrompts.verifyUser(passage: passage, kind: kind, text: c.text, owner: c.owner, due: c.due)
        return try cached(["verify", user]) {
            let r = try generator.generate(prompt: generator.chatPrompt(system: NotesPrompts.verifySystem, user: user),
                                           grammar: NotesPrompts.verifyGrammar, maxTokens: 120, cancellation: cancellation)
            return try? JSONDecoder().decode(NotesPrompts.VerifyOutput.self, from: Data(r.text.utf8))
        }
    }

    func makeOverview(_ items: [Candidate], refs: ([Int]) -> [EvidenceRef], passage: ([Int]) -> String,
                      cancellation: CancellationToken) throws -> [SummaryItem] {
        let usable = items.filter { !$0.uncertain }.prefix(80)
        guard !usable.isEmpty else { return [] }
        let numbered = usable.enumerated().map { (i, c) in (i + 1, c.kind.rawValue, c.text) }
        let user = NotesPrompts.overviewUser(numbered)
        guard let out = try cached(["overview", user], {
            let r = try generator.generate(prompt: generator.chatPrompt(system: NotesPrompts.overviewSystem, user: user),
                                           grammar: NotesPrompts.overviewGrammar, maxTokens: 500, cancellation: cancellation)
            return try? JSONDecoder().decode(NotesPrompts.OverviewOutput.self, from: Data(r.text.utf8))
        }) else { return [] }
        let list = Array(usable)
        return out.overview.enumerated().compactMap { (n, s) -> SummaryItem? in
            let cited = s.items.filter { $0 >= 1 && $0 <= list.count }.map { list[$0 - 1] }
            guard !cited.isEmpty else { return nil }   // an uncited sentence is not kept
            let allLines = Array(Set(cited.flatMap(\.lines))).sorted()
            // Grounding: every name and number in a sentence must occur in the cited items' lines; otherwise drop it.
            let text0 = s.text
            let p = passage(allLines)
            guard EvidenceChecker.unsupportedNames(text0, passage: p).isEmpty, EvidenceChecker.unsupportedNumbers(text0, passage: p).isEmpty else {
                diagnostics.droppedOverviewSentences += 1
                return nil
            }
            let lines = allLines.prefix(8)
            // The model sometimes repeats its item citations in the text ("(items 1, 3)"); citations live in evidence.
            let text = s.text.replacingOccurrences(of: #"\s*\((items?|see items?)\s*[\d,\s&and]+\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            return SummaryItem(id: SummaryItemID("overview-\(n)"), kind: .overview, text: text, evidence: refs(Array(lines)))
        }
    }

    // MARK: Reduce

    func reduce(_ items: [Candidate], doc: NotesInputDocument) -> [Candidate] {
        var out: [Candidate] = []
        for c in items.sorted(by: { $0.firstLine < $1.firstLine }) {
            if let i = out.firstIndex(where: { Self.sameItem($0, c) }) {
                var m = out[i]
                m.lines = Array(Set(m.lines + c.lines)).sorted()
                if m.lines.count > 8 { m.lines = Array(m.lines.prefix(4) + m.lines.suffix(4)) }
                if c.text.count > m.text.count, c.lines.count >= m.lines.count / 2 { m.text = c.text }
                if m.owner == nil { m.owner = c.owner } else if let o = c.owner, o != m.owner { m.owner = nil; m.uncertain = true }
                if m.due == nil { m.due = c.due } else if let d = c.due, d != m.due { m.due = nil; m.uncertain = true }
                m.title = m.title ?? c.title
                m.uncertain = m.uncertain || c.uncertain
                out[i] = m
                diagnostics.merged += 1
            } else {
                out.append(c)
            }
        }
        // Per-kind caps, spread across the meeting rather than truncating at the end.
        var kept: [Candidate] = []
        for (kind, group) in Dictionary(grouping: out, by: \.kind).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let cap = options.caps[kind.rawValue] ?? Int.max
            guard group.count > cap else { kept += group; continue }
            let ordered = group.sorted { $0.firstLine < $1.firstLine }
            let picked = (0..<cap).map { ordered[$0 * ordered.count / cap] }
            diagnostics.cappedOut += group.count - cap
            kept += picked
        }
        return kept
    }

    static func sameItem(_ a: Candidate, _ b: Candidate) -> Bool {
        guard a.kind == b.kind else { return false }
        // A negation mismatch means a revision or contradiction: keep both.
        guard EvidenceChecker.hasNegation(a.text) == EvidenceChecker.hasNegation(b.text) else { return false }
        guard EvidenceChecker.numbers(a.text) == EvidenceChecker.numbers(b.text) else { return false }
        let wa = Set(EvidenceChecker.words(a.text).filter { !EvidenceChecker.stopwords.contains($0) }.map(EvidenceChecker.stem))
        let wb = Set(EvidenceChecker.words(b.text).filter { !EvidenceChecker.stopwords.contains($0) }.map(EvidenceChecker.stem))
        let jaccard = Double(wa.intersection(wb).count) / Double(max(1, wa.union(wb).count))
        let shared = Set(a.lines).intersection(b.lines).count
        return jaccard >= 0.6 || (shared > 0 && jaccard >= 0.3)
    }

    // MARK: Limitations (computed)

    func computedLimitations(transcript: TranscriptRevision, doc: NotesInputDocument, scratchpadIncluded: Bool) -> [String] {
        var out: [String] = []
        func total(_ s: CoverageRegion.Status) -> Double {
            transcript.coverage.filter { $0.status == s }.map(\.interval.duration.seconds).reduce(0, +)
        }
        func fmt(_ s: Double) -> String { s >= 90 ? "\(Int((s / 60).rounded())) min" : "\(Int(s.rounded())) s" }
        if total(.missingAudio) >= 5 { out.append("\(fmt(total(.missingAudio))) of audio was not recorded; nothing from that time is reflected here.") }
        if total(.failed) >= 5 { out.append("\(fmt(total(.failed))) of detected speech could not be transcribed; notes may miss what was said then.") }
        if total(.unsupportedLanguage) >= 5 { out.append("\(fmt(total(.unsupportedLanguage))) of speech was in an unsupported language.") }
        let words = transcript.allWords
        if !words.isEmpty, transcript.stage == .attributed {
            let unknown = words.filter { $0.speaker == .unknown }.count
            if Double(unknown) / Double(words.count) >= 0.05 {
                out.append("\(Int((Double(unknown) / Double(words.count) * 100).rounded()))% of words have no speaker; owners may be missing.")
            }
        } else if !words.isEmpty {
            out.append("Speakers were not yet identified when these notes were made; owners may be missing.")
        }
        let questionable = words.filter { $0.flags.contains(.questionableText) }.count
        if questionable > 0 { out.append("\(questionable) words were flagged as possibly garbled by speech recognition.") }
        if doc.lines.contains(where: { !$0.isPersonalNote && EvidenceChecker.looksAddressedToAI($0.text) }) {
            out.append("Someone in the meeting addressed the notes or an AI directly; that was treated as speech, not as instructions.")
        }
        if scratchpadIncluded { out.append("These notes also used your personal notes, which were not spoken in the meeting.") }
        let d = diagnostics
        let dropped = d.droppedInvalidEvidence + d.droppedAddressedToAI + d.droppedByVerifier
        if dropped > 0 { out.append("\(dropped) generated items were removed because the transcript did not support them.") }
        if d.cappedOut > 0 { out.append("\(d.cappedOut) lower-priority items were left out to keep the notes readable.") }
        out.append("Generated locally by a small language model; check important items against the cited transcript.")
        return out
    }

    // MARK: Helpers

    static func kind(_ s: String) -> SummaryItemKind? {
        switch s { case "decision": .decision; case "action": .actionItem; case "question": .openQuestion; case "topic": .topic; default: nil }
    }

    static func shortTitle(_ text: String) -> String {
        let w = text.split(separator: " ").prefix(6).joined(separator: " ")
        return w.trimmingCharacters(in: .punctuationCharacters)
    }

    static func messages(_ d: Diagnostics) -> [String] {
        ["chunks=\(d.chunks) failed=\(d.failedChunks.count) repairs=\(d.repairs) extracted=\(d.extracted) verifications=\(d.verifications)",
         "dropped: invalidEvidence=\(d.droppedInvalidEvidence) addressedToAI=\(d.droppedAddressedToAI) verifier=\(d.droppedByVerifier)",
         "demotedProposals=\(d.demotedProposals) removedOwners=\(d.removedOwners) removedDue=\(d.removedDue) merged=\(d.merged) cappedOut=\(d.cappedOut) uncertain=\(d.uncertain) droppedOverviewSentences=\(d.droppedOverviewSentences)"]
    }
}
