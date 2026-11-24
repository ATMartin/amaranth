public import Foundation
public import Domain

/// What the toolbar recording strip shows (T31): one glyph per active source, coloured by health, with the same
/// status text the old sidebar recorder used as its tooltip.
public enum RecorderPresentation {
    /// RMS below this is "silent" (the recorder's health rule); the quiet alert's fallback when live text isn't running.
    public static let silentDBFS: Double = -70

    public enum Tone: Sendable, Equatable { case green, grey, orange, red }

    public static func tone(_ s: SourceHealth.Status) -> Tone {
        switch s {
        case .healthy: .green
        case .silent, .starting, .inactive: .grey
        case .clipping, .degraded: .orange
        case .failed, .permissionDenied: .red
        }
    }

    public static func symbol(_ source: SourceKind) -> String {
        source == .microphone ? "mic.fill" : "speaker.wave.2.fill"
    }

    public static func sourceName(_ source: SourceKind) -> String {
        source == .microphone ? "Microphone" : "System audio"
    }

    /// Saving is "delayed" when the durable copy trails the recording clock by more than 8 s.
    public static func statusText(_ s: SourceHealth.Status, savedUpTo: Double?, now: Double) -> String {
        let lag = savedUpTo.map { now - $0 } ?? 0
        let saved = savedUpTo != nil && lag > 8 ? " · saving delayed" : ""
        return switch s {
        case .healthy: "OK" + saved
        case .silent: "Silent (still recording)" + saved
        case .clipping: "Too loud (clipping)"
        case .degraded: "Interrupted — gap marked"
        case .failed: "Not recording — source failed"
        case .permissionDenied: "Permission denied — see System Settings"
        case .starting: "Starting"
        case .inactive: "Off"
        }
    }

    /// Tooltip / VoiceOver text of a source glyph: "Microphone: OK · MacBook Pro Microphone · Saved up to 00:12:04".
    public static func tooltip(_ h: SourceHealth, savedUpTo: Double?, now: Double) -> String {
        "\(sourceName(h.source)): \(statusText(h.status, savedUpTo: savedUpTo, now: now))"
            + [h.deviceName, savedUpTo.map { "Saved up to \(clock($0))" }].compactMap { $0 }.map { " · \($0)" }.joined()
    }

    public static func diskWarning(secondsLeft: Double) -> String {
        "Low disk space: about \(Int(secondsLeft / 60)) min of recording left. Amaranth will stop and save before the disk is full."
    }

    public static let consent = "Amaranth records only when you press Record; let participants know."

    /// Elapsed recording time, always with hours: "01:02:03".
    public static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    /// Title for a meeting started without one: "Meeting — Oct 23, 2026 10:01 AM" (time in the user's 12/24 h style).
    public static func automaticTitle(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var d = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale); d.timeZone = timeZone
        var t = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale); t.timeZone = timeZone
        return "Meeting — \(date.formatted(d)) \(date.formatted(t))"
    }

    /// The title to record with: the typed one if any, otherwise the automatic one.
    public static func recordingTitle(typed: String, at date: Date) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? automaticTitle(date) : t
    }
}
