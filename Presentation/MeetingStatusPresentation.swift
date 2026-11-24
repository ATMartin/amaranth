public import Domain

/// One status glyph per meeting (T27): the sidebar card and the quick-review header show this instead of the two
/// badge lines. The tooltip doubles as the VoiceOver label. Switches are exhaustive, so a new headline case cannot
/// compile without a glyph.
public enum MeetingStatusPresentation {
    public enum Tone: Hashable, Sendable { case secondary, red, orange }

    public struct Glyph: Hashable, Sendable {
        /// SF Symbol name; nil when `spinner` is true.
        public var symbol: String?
        /// Work in progress: a small activity indicator instead of a symbol.
        public var spinner: Bool
        public var tone: Tone
        public var tooltip: String
    }

    public static func glyph(_ s: MeetingStatus) -> Glyph {
        func sym(_ name: String, _ tone: Tone, _ tip: String) -> Glyph { Glyph(symbol: name, spinner: false, tone: tone, tooltip: tip) }
        // Capture states come first: while audio is still being recorded or saved, processing is secondary.
        switch s.audio {
        case .recording: return sym("record.circle", .red, "Recording")
        case .paused: return sym("pause.circle", .secondary, "Recording paused")
        case .saving: return sym("arrow.down.circle", .secondary, "Saving audio…")
        case .notStarted, .saved, .savedWithGaps, .interrupted, .audioDeleted: break
        }
        switch s.processing {
        case .failed(let stage, _): return sym("exclamationmark.triangle", .red, "\(stageName(stage)) failed — retry available")
        case .running(let stage, let p): return Glyph(symbol: nil, spinner: true, tone: .secondary, tooltip: "\(stageName(stage)) \(Int(p * 100))%")
        case .waiting(nil): return Glyph(symbol: nil, spinner: true, tone: .secondary, tooltip: waiting(nil))
        case .waiting(let r): return sym("hourglass", .secondary, waiting(r))
        case .cancelled(let stage): return sym("stop.circle", .secondary, "\(stageName(stage)) stopped — retry available")
        case .notQueued:
            switch s.audio {
            case .audioDeleted: return sym("trash", .secondary, "Audio deleted; not processed")
            case .notStarted: return sym("circle.dashed", .secondary, "No audio recorded")
            default: return sym("circle.dashed", .secondary, "Not processed")
            }
        case .complete:
            switch s.audio {
            case .savedWithGaps(let missing):
                return sym("exclamationmark.circle", .orange, "Processed · \(Int(missing.rounded()).formatted()) s of audio missing — see Recording tab")
            case .interrupted: return sym("exclamationmark.circle", .orange, "Processed · recording was interrupted — see Recording tab")
            case .audioDeleted: return sym("trash", .secondary, "Audio deleted; transcript and notes kept")
            case .notStarted: return sym("checkmark.circle", .secondary, "Processed")
            case .saved, .recording, .paused, .saving: return sym("checkmark.circle", .secondary, "Processed · audio saved")
            }
        }
    }

    /// The meeting card's glyph (T80): only work in progress (a spinner while saving or processing, queued or paused
    /// included) and failed processing (Retry needed). Everything else shows nothing on the card; the header keeps the
    /// full `glyph` and its tooltip.
    public static func cardGlyph(_ s: MeetingStatus) -> Glyph? {
        if s.audio == .recording || s.audio == .paused { return nil }   // the toolbar strip shows the recording
        let full = glyph(s)
        if s.audio == .saving { return Glyph(symbol: nil, spinner: true, tone: .secondary, tooltip: full.tooltip) }
        switch s.processing {
        case .running, .waiting: return Glyph(symbol: nil, spinner: true, tone: .secondary, tooltip: full.tooltip)
        case .failed: return full
        case .notQueued, .complete, .cancelled: return nil
        }
    }

    public static func waiting(_ r: SuspensionReason?) -> String {
        switch r {
        case .recordingActive: "Queued · paused while recording"
        case .thermalPressure: "Queued · paused while the Mac is hot"
        case .memoryPressure: "Queued · paused while memory is low"
        case .captureFault: "Queued · paused to protect the recording"
        case .userPaused: "Paused"
        case nil: "Queued"
        }
    }

    public static func stageName(_ s: ProcessingStage) -> String {
        switch s {
        case .prepare: "Preparing audio"
        case .transcribe: "Transcribing"
        case .diarize: "Finding speakers"
        case .reconcile: "Matching speakers"
        case .notes: "Writing notes"
        case .live: "Live text"
        }
    }
}
