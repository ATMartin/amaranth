public import Domain

/// Audio details in plain language (Inner Circle handoff): a one-line summary, then one notice per stretch of missing
/// audio with where to listen. It only says what the capture events record: which source, when and for how long, and
/// whether the other source has audio there. It never guesses a cause; the raw events stay listed below it.
public enum AudioDetails {
    public struct Issue: Hashable, Sendable {
        public var source: SourceKind?
        public var start: SessionTime
        public var end: SessionTime
        public var title: String
        public var body: String
    }

    public static func issues(_ events: [CaptureEvent], recordedSources: Set<SourceKind>) -> [Issue] {
        let missing = events.filter(\.isMissingAudio).sorted { $0.interval.start < $1.interval.start }
        return missing.map { e in
            let what = e.source.map(sourceName) ?? "Audio"
            let span = e.interval.duration.seconds
            let title = span >= 0.5 ? "\(what) gap · \(length(span))" : "\(what) gap"
            var body: String
            switch e.kind {
            case .permissionDenied:
                body = "\(what) access was not allowed, so nothing was recorded from it after \(TranscriptRows.clock(e.interval.start))."
            default:
                body = span >= 0.5
                    ? "No \(e.source.map { sourceName($0).lowercased() } ?? "audio") from \(TranscriptRows.clock(e.interval.start)) to \(TranscriptRows.clock(e.interval.end))."
                    : "Some \(e.source.map { sourceName($0).lowercased() } ?? "audio") is missing at \(TranscriptRows.clock(e.interval.start))."
            }
            if let s = e.source, let other = SourceKind.allCases.first(where: { $0 != s }), recordedSources.contains(other),
               !missing.contains(where: { ($0.source == other || $0.source == nil) && $0.interval.start < e.interval.end && e.interval.start < $0.interval.end }) {
                body += " \(sourceName(other)) continued."
            }
            return Issue(source: e.source, start: e.interval.start, end: e.interval.end, title: title, body: body)
        }
    }

    public static func headline(issues: Int, audioDeleted: Bool) -> String {
        if audioDeleted { return "The audio was deleted." }
        switch issues {
        case 0: return "Recorded without gaps."
        case 1: return "One moment needs a closer look."
        default: return "\(issues) moments need a closer look."
        }
    }

    public static func sourceName(_ s: SourceKind) -> String { s == .microphone ? "Microphone" : "System audio" }

    /// "8 seconds", "1 second", "2 min 5 s".
    public static func length(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }

    /// The sources line: "Microphone + system audio", "Microphone only", "System audio only", or "None".
    public static func sourcesLabel(_ sources: Set<SourceKind>) -> String {
        switch (sources.contains(.microphone), sources.contains(.systemOutput)) {
        case (true, true): "Microphone + system audio"
        case (true, false): "Microphone only"
        case (false, true): "System audio only"
        case (false, false): "None"
        }
    }
}
