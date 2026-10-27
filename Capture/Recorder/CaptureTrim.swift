public import Foundation
public import Domain
public import Storage

/// Ends a just-stopped recording at an earlier point (T68: stopping while the "Still recording?" alert is up ends the
/// meeting at the last words + 5 s). The quiet tail is deleted, not hidden: there is no restore (user decision,
/// docs/decisions/capture/0002). Whole 2 s segments are kept or dropped, so the meeting ends at most one segment after
/// the cut. Rows go first, then files, then the journal lines, so crash recovery (which re-indexes files and replays the
/// journal) can't bring the tail back once this returns; a crash part-way leaves extra audio, never less.
public enum CaptureTrim {
    public struct Plan: Sendable, Equatable {
        public var keep: [AudioSegmentRecord]
        public var drop: [AudioSegmentRecord]
        public var dropEvents: [CaptureEvent]
        public var keptEvents: [CaptureEvent]
        public var duration: SessionDuration
        /// Seconds of recording removed.
        public var removedSeconds: Double
    }

    /// Segments and events starting at or after `end` go; the duration becomes the end of the last kept segment (at
    /// least `end`, never more than before). Nil when nothing would change.
    public static func plan(segments: [AudioSegmentRecord], events: [CaptureEvent], duration: SessionDuration, end: SessionTime) -> Plan? {
        guard end.nanoseconds < duration.nanoseconds else { return nil }
        let keep = segments.filter { $0.interval.start < end }, drop = segments.filter { $0.interval.start >= end }
        let keptEnd = keep.map(\.interval.end.nanoseconds).max() ?? 0
        let newDuration = SessionDuration(nanoseconds: min(duration.nanoseconds, max(end.nanoseconds, keptEnd)))
        guard newDuration.nanoseconds < duration.nanoseconds else { return nil }
        // Events running past the new end (an open gap or pause) are clipped to it, so nothing counts time after the end.
        let newEnd = SessionTime(nanoseconds: newDuration.nanoseconds)
        let kept = events.filter { $0.interval.start < end }.map { e -> CaptureEvent in
            guard e.interval.end > newEnd else { return e }
            var c = e
            c.interval = SessionInterval(unchecked: e.interval.start, max(e.interval.start, newEnd))
            return c
        }
        return Plan(keep: keep, drop: drop, dropEvents: events.filter { $0.interval.start >= end }, keptEvents: kept,
                    duration: newDuration, removedSeconds: duration.seconds - newDuration.seconds)
    }

    public static func plan(_ r: CaptureResult, end: SessionTime) -> Plan? {
        plan(segments: r.segments, events: r.events, duration: r.duration, end: end)
    }

    /// Applies `plan` to the stopped recording `r` and returns the result as it now is.
    public static func apply(_ plan: Plan, to r: CaptureResult, store: MeetingStore?) throws -> CaptureResult {
        // "With gaps" only if a gap is left in the kept part.
        var state = r.finalState
        if state == .capturedWithGaps, !plan.keptEvents.contains(where: \.isMissingAudio) { state = .captured }
        let clipped = plan.keptEvents.filter { k in r.events.first { $0.id == k.id }?.interval != k.interval }
        try store?.trimCapture(r.meetingID, removingSegments: plan.drop.map(\.id), events: plan.dropEvents.map(\.id), replacingEvents: clipped,
                               duration: plan.duration, captureState: state)
        for s in plan.drop { try? FileManager.default.removeItem(at: r.directory.appending(path: s.relativePath)) }
        try rewriteJournal(in: r.directory, dropping: Set(plan.drop.map(\.relativePath)), events: Set(plan.dropEvents.map(\.id)))
        var out = r
        out.segments = plan.keep
        out.events = plan.keptEvents
        out.duration = plan.duration
        out.finalState = state
        return out
    }

    /// Drops the tail's segment and event lines; keeps every other line byte for byte (including any it can't read).
    static func rewriteJournal(in directory: URL, dropping paths: Set<String>, events: Set<CaptureEventID>) throws {
        let url = directory.appending(path: "journal.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            switch try? ContractCoding.decode(JournalEntry.self, from: Data(line.utf8)) {
            case .segment(let s)?: !paths.contains(s.relativePath)
            case .event(let e)?: !events.contains(e.id)
            default: true
            }
        }
        try Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)
    }
}
