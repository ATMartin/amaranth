public import Foundation
public import Domain
public import Storage
import CryptoKit

/// Reads meetings for external use (spec 0009): consistent per-meeting snapshots and citation resolution. Everything
/// goes through the app's `MeetingStore` (its single queue and migration owner); nothing here writes meeting content,
/// loads a model or touches audio.
public struct MeetingReader: Sendable {
    public let store: MeetingStore

    public init(store: MeetingStore) { self.store = store }

    /// The meeting as it is shown now, or nil when it doesn't exist or was deleted.
    public func snapshot(_ id: MeetingID, now: Date = Date()) throws -> MeetingSnapshot? {
        guard let records = try store.readMeetingSource(id) else { return nil }
        return SnapshotBuilder.build(records, libraryID: try store.libraryID(), readAt: now)
    }

    /// Resolves a citation URL against current content. Invalid text never reaches the database.
    public func resolve(_ text: String) -> CitationResolution {
        switch SourceURL.parse(text) {
        case .failure(let e): if case .invalidRequest(let why) = e { return .invalid(why) }; return .invalid("url")
        case .success(let url):
            guard let snap = try? snapshot(url.meetingID) else { return .unavailable }
            return snap.resolve(url)
        }
    }
}

/// Builds the external snapshot from stored records. Pure: same records and read time, same snapshot.
public enum SnapshotBuilder {
    public static func build(_ r: MeetingSourceRecords, libraryID: String, readAt: Date) -> MeetingSnapshot {
        let m = r.meeting
        let status = MeetingStatus(meeting: m, jobs: r.jobs, events: r.events)
        let displayed = r.transcript?.applyingTextEdits(r.edits)
        let names = displayed.map { MeetingStore.speakerNames($0.speakers, r.edits) } ?? [:]
        let removedLines = r.edits.contains { e in
            guard e.conflict == .applied else { return false }
            switch e.operation { case .deleteText, .trimTranscript: return true; default: return false }
        }
        let corrected = Set(r.edits.compactMap { e -> WordID? in
            if case .correctText(let range, _) = e.operation, e.conflict == .applied { range.first } else { nil }
        })

        // Transcript lines: one per speaker run within a segment (the app's rows; a line's citation is its row).
        var lines: [MeetingSnapshot.TranscriptLine] = []
        if let t = displayed {
            for seg in t.segments {
                var run: [Word] = []
                func flush() {
                    guard let f = run.first, let l = run.last else { return }
                    var flags: [String] = []
                    if run.contains(where: { $0.flags.contains(.overlap) }) || { if case .multiple = f.speaker { true } else { false } }() { flags.append("overlap") }
                    if run.contains(where: { $0.flags.contains(.uncertainSpeaker) }) { flags.append("uncertainSpeaker") }
                    if run.contains(where: { $0.flags.contains(.questionableText) }) { flags.append("questionableText") }
                    if run.contains(where: { $0.flags.contains(.probableEchoDuplicate) }) { flags.append("probableEcho") }
                    if run.contains(where: { corrected.contains($0.id) }) { flags.append("corrected") }
                    let text = run.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
                    run = []
                    guard !text.isEmpty else { return }
                    let url = SourceURL(meetingID: m.id, source: .transcript, ref: seg.id.rawValue, word: f.id.rawValue, revision: t.id.rawValue,
                                        hash: SourceURL.lineHash(text))
                    lines.append(.init(segmentID: seg.id.rawValue, wordID: f.id.rawValue, startNs: f.interval.start.nanoseconds,
                                       endNs: l.interval.end.nanoseconds, source: seg.source.rawValue, speaker: label(f.speaker, names),
                                       speakerIDs: f.speaker.speakerIDs.map(\.rawValue), text: text, flags: flags, citation: url.string))
                }
                for w in seg.words {
                    if let f = run.first, f.speaker != w.speaker { flush() }
                    run.append(w)
                }
                flush()
            }
            lines = lines.enumerated().sorted { ($0.element.startNs, $0.offset) < ($1.element.startNs, $1.offset) }.map(\.element)
        }
        let gaps: [MeetingSnapshot.Gap] = (displayed?.coverage ?? []).compactMap { c in
            guard let reason = gapReason(c.status), c.interval.duration.seconds >= 1 else { return nil }
            return .init(source: c.source.rawValue, startNs: c.interval.start.nanoseconds, endNs: c.interval.end.nanoseconds, reason: reason)
        }.sorted { ($0.startNs, $0.source) < ($1.startNs, $1.source) }

        // Notes: the document as shown. Evidence carries IDs and times only, and says whether it still resolves.
        var wordLine: [String: MeetingSnapshot.TranscriptLine] = [:]
        if let t = displayed {
            var byRun: [String: MeetingSnapshot.TranscriptLine] = [:]
            for l in lines { byRun[l.segmentID + "/" + l.wordID] = l }
            for seg in t.segments {
                var current: MeetingSnapshot.TranscriptLine?
                for w in seg.words {
                    if let l = byRun[seg.id.rawValue + "/" + w.id.rawValue] { current = l }
                    if let current { wordLine[w.id.rawValue] = current }
                }
            }
        }
        let doc = r.notes
        let userBlockIDs = Set((doc?.blocks ?? []).filter(\.isUser).map(\.id.rawValue))
        var noteLines: [MeetingSnapshot.NoteLine] = []
        for b in doc?.blocks ?? [] where !b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let evidence: [MeetingSnapshot.Evidence] = b.evidence.compactMap { ref in
                switch ref {
                case .transcript(let e):
                    guard let t = displayed, e.revisionID == t.id else {
                        return .init(type: "transcript", status: "otherRevision", revisionID: e.revisionID.rawValue, segmentID: e.segmentID.rawValue,
                                     firstWordID: e.firstWord.rawValue, lastWordID: e.lastWord.rawValue, blockID: nil, startNs: nil, citation: nil)
                    }
                    let shown = t.segment(e.segmentID)?.words.first { $0.id == e.firstWord }
                    let line = shown.flatMap { wordLine[$0.id.rawValue] }
                    return .init(type: "transcript", status: line == nil ? "removed" : "current", revisionID: e.revisionID.rawValue,
                                 segmentID: e.segmentID.rawValue, firstWordID: e.firstWord.rawValue, lastWordID: e.lastWord.rawValue, blockID: nil,
                                 startNs: line == nil ? nil : shown?.interval.start.nanoseconds, citation: line?.citation)
                case .userNote(let n):
                    let present = userBlockIDs.contains(n.blockID.rawValue)
                    return .init(type: "userNote", status: present ? "current" : "removed", revisionID: n.revisionID.rawValue, segmentID: nil,
                                 firstWordID: nil, lastWordID: nil, blockID: n.blockID.rawValue, startNs: nil,
                                 citation: present ? doc.flatMap { d in d.blocks.first { $0.id == n.blockID }.map { noteURL(m.id, d, $0) } } : nil)
                case .personalNote:
                    return nil   // pre-0008 private text: never cited outward
                }
            }
            let typedAt: Double? = if case .user(let at) = b.author { at } else { nil }
            noteLines.append(.init(blockID: b.id.rawValue, kind: b.kind.rawValue, section: b.section?.rawValue, text: b.text, detail: b.detail,
                                   author: b.isUser ? "user" : "model", typedAtSeconds: typedAt, uncertain: b.isUncertain,
                                   evidence: evidence, citation: doc.map { noteURL(m.id, $0, b) } ?? ""))
        }

        let notesJob = r.jobs.filter { $0.key.stage == .notes }.max { $0.updatedAt < $1.updatedAt }
        let notesState: String = if let j = notesJob, !j.state.isTerminal { "generating" }
            else if !noteLines.isEmpty { "ready" }
            else if notesJob?.state == .failed { "failed" }
            else { "none" }
        let state = MeetingSnapshot.ContentState(
            capture: capture(status.audio), audio: m.audio == .deletedByUser ? "deleted" : "present",
            transcript: transcriptState(r, status), notes: notesState, notesStale: r.notesSummary?.isStale ?? false,
            newerNotesPending: r.hasPendingNotes, editsNeedingReview: r.edits.filter { $0.conflict == .needsReview }.count,
            transcriptLinesRemoved: removedLines)

        var limits: [String] = []
        if state.transcript == "provisional" { limits.append("The transcript is live text from the recording; it may change when processing finishes.") }
        if displayed == nil, !noteLines.isEmpty { limits.append("This meeting has no transcript; its notes are shown on their own.") }
        if removedLines, !noteLines.isEmpty {
            limits.append("Transcript lines were deleted or trimmed. The notes are shown as they are and may still mention removed discussion; removing a topic also needs the notes edited or regenerated.")
        }
        if state.notesStale { limits.append("The generated notes were made from an earlier version of the transcript.") }
        if noteLines.contains(where: { $0.author == "user" }) { limits.append("Notes lines by \"user\" were written or edited by a person; they are not something said in the meeting.") }
        if noteLines.contains(where: \.uncertain) { limits.append("Lines marked uncertain could not be fully checked against the transcript.") }
        if noteLines.contains(where: { $0.author == "model" && $0.kind != "heading" }) {
            limits.append("Generated notes and transcription can contain errors; check important items against the cited lines.")
        }
        if !gaps.isEmpty { limits.append("Some stretches have no transcript; they are listed under gaps.") }
        if !m.people.isEmpty { limits.append("People lists who was in the meeting, not who said a given line.") }
        if m.audio == .deletedByUser { limits.append("The audio was deleted; the text remains.") }

        var snap = MeetingSnapshot(
            libraryID: libraryID, meetingID: m.id.rawValue, fingerprint: "", readAt: ms(readAt), title: m.title,
            start: ms(m.clock?.utcOrigin ?? m.createdAt), timeZone: m.clock?.timeZoneIdentifier, durationNs: m.duration.nanoseconds,
            folder: r.folder.map { .init(id: $0.id.rawValue, name: $0.name) }, people: m.people.map(\.name), state: state,
            revisions: .init(transcript: displayed?.id.rawValue, transcriptKind: displayed?.kind.rawValue, notes: doc?.id.rawValue,
                             editSequence: r.edits.map(\.sequence).max() ?? 0),
            generatedNotes: r.notesSummary.map { .init(revisionID: $0.id.rawValue, promptVersion: $0.promptVersion, generatedAt: ms($0.createdAt),
                                                         fromTranscriptRevision: $0.transcriptRevisionID.rawValue, stale: $0.isStale) },
            speakers: (displayed?.speakers ?? []).map { .init(id: $0.id.rawValue, name: names[$0.id] ?? $0.shownName) },
            transcript: lines, gaps: gaps, notes: noteLines, limitations: limits,
            citation: SourceURL(meetingID: m.id).string)
        snap.fingerprint = fingerprint(snap)
        return snap
    }

    /// SHA-256 over the canonical encoding without `readAt` and the fingerprint itself.
    public static func fingerprint(_ s: MeetingSnapshot) -> String {
        var c = s
        c.readAt = Date(timeIntervalSince1970: 0)
        c.fingerprint = ""
        let data = (try? ExternalCoding.encoder(pretty: false).encode(c)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Dates go out with millisecond precision (what ISO-8601 carries), so a decoded snapshot equals the original.
    static func ms(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000) }

    static func noteURL(_ id: MeetingID, _ d: NotesDocumentRevision, _ b: NoteBlock) -> String {
        SourceURL(meetingID: id, source: b.isUser ? .userNote : .notes, ref: b.id.rawValue, revision: d.id.rawValue,
                  hash: SourceURL.lineHash(NoteLineText.hashed(b.text, b.detail))).string
    }

    static func label(_ a: SpeakerAssignment, _ names: [SpeakerID: String]) -> String {
        switch a {
        case .unknown: "Unknown speaker"
        case .speaker(let id): names[id] ?? "Unknown speaker"
        case .multiple(let ids): ids.map { names[$0] ?? "Unknown" }.joined(separator: " + ") + " (overlapping)"
        }
    }

    static func gapReason(_ s: CoverageRegion.Status) -> String? {
        switch s {
        case .missingAudio: "audio not recorded"
        case .failed: "speech could not be transcribed"
        case .paused: "recording paused"
        case .unsupportedLanguage: "unsupported language"
        case .pending: "not yet transcribed"
        case .transcribed, .noSpeech: nil
        }
    }

    static func capture(_ a: MeetingStatus.AudioHeadline) -> String {
        switch a {
        case .notStarted: "notStarted"
        case .recording: "recording"
        case .paused: "paused"
        case .saving: "saving"
        case .saved, .audioDeleted: "saved"
        case .savedWithGaps: "savedWithGaps"
        case .interrupted: "interrupted"
        }
    }

    static func transcriptState(_ r: MeetingSourceRecords, _ status: MeetingStatus) -> String {
        if let t = r.transcript { return t.kind == .final ? "final" : "provisional" }
        let stages: [ProcessingStage] = [.prepare, .transcribe]
        if stages.contains(where: { status.stages[$0] == .failed }) { return "failed" }
        if stages.contains(where: { status.stages[$0].map { !$0.isTerminal } ?? false }) { return "processing" }
        if [.recording, .paused, .saving].contains(status.audio) { return "processing" }
        return "none"
    }
}

/// The JSON coding every external payload uses: sorted keys, UTC ISO-8601 dates with fractional seconds.
public enum ExternalCoding {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in var c = enc.singleValueContainer(); try c.encode(iso.string(from: date)) }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = iso.date(from: s) else { throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date \(s)")) }
            return date
        }
        return d
    }
}
