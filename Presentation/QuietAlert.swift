public import Foundation

/// Settings → Recording: "Alert when a recording goes quiet" and its threshold (T68, docs/decisions/capture/0002).
public enum QuietAlertSettings {
    public static let enabledKey = "quietAlertEnabled"
    public static let thresholdKey = "quietAlertSeconds"
    /// Set once Amaranth has asked for notification permission after a recording (never during one).
    public static let askedKey = "quietAlertNotificationsAsked"
    public static let defaultThreshold: Double = 60
    /// The Settings choices: 30 s to 5 min.
    public static let choices: [Double] = [30, 60, 120, 180, 300]

    public static func enabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: enabledKey) as? Bool ?? true }

    public static func threshold(_ d: UserDefaults = .standard) -> Double {
        let v = d.object(forKey: thresholdKey) as? Double ?? defaultThreshold
        return min(max(v, choices.first!), choices.last!)
    }

    /// "30 s", "1 min", "2 min"…
    public static func label(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

/// Decides when a recording has gone quiet (T68). Pure: the recorder feeds it one `Input` per tick (session seconds,
/// live words, levels, other apps' microphone use) and reads `alert`. It never stops anything.
///
/// Two signals, either raises the alert:
/// - **Quiet:** no live word on either source for `threshold` seconds. Words, not levels, because hum and music hold a
///   level up. When live text isn't running, every source's level below the silent line counts as quiet instead.
/// - **Call ended:** another app used the microphone during this recording and none has for `micReleaseDelay` seconds.
///
/// Paused time never counts. **Keep Recording** silences the alert until speech resumes; after that the quiet signal is
/// armed again, and the call-ended signal once another app uses the microphone again.
public struct QuietMonitor: Sendable {
    public enum Reason: Equatable, Sendable { case quiet, callEnded }

    public struct Alert: Equatable, Sendable {
        public var reason: Reason
        /// Session seconds of the last speech (or the start / resume, when nobody has spoken since).
        public var quietSince: Double
        /// Live text wasn't running, so levels decided "quiet".
        public var usedLevels: Bool
        public init(reason: Reason, quietSince: Double, usedLevels: Bool) {
            self.reason = reason; self.quietSince = quietSince; self.usedLevels = usedLevels
        }
    }

    public struct Input: Sendable {
        /// Session seconds (including pauses).
        public var now: Double
        /// False while paused, interrupted, starting or saving.
        public var recording: Bool
        /// Live text is running, so `lastWordEnd` is meaningful.
        public var liveText: Bool
        /// End of the newest live word on any source, in session seconds.
        public var lastWordEnd: Double?
        /// Every recorded source is below the silent level (the fallback when live text isn't running).
        public var levelsSilent: Bool
        /// Whether any other app is using audio input; nil when unknown.
        public var othersUsingMicrophone: Bool?

        public init(now: Double, recording: Bool, liveText: Bool, lastWordEnd: Double?, levelsSilent: Bool, othersUsingMicrophone: Bool?) {
            self.now = now; self.recording = recording; self.liveText = liveText; self.lastWordEnd = lastWordEnd
            self.levelsSilent = levelsSilent; self.othersUsingMicrophone = othersUsingMicrophone
        }
    }

    public let threshold: Double
    public let micReleaseDelay: Double
    public private(set) var alert: Alert?
    /// Session seconds of the last speech heard (a live word's end, or a non-silent level); nil until someone speaks.
    public private(set) var lastSpeech: Double?
    /// Start of the current quiet stretch: the last speech, or when recording (re)started.
    private var quietFrom: Double = 0
    private var wasRecording = false
    private var snoozed = false
    private var micSeen = false
    private var micReleasedAt: Double?

    public init(threshold: Double = QuietAlertSettings.defaultThreshold, micReleaseDelay: Double = 30) {
        self.threshold = threshold
        self.micReleaseDelay = micReleaseDelay
    }

    /// Feeds one tick. Returns the alert when it was raised by this tick (to post one notification), else nil.
    @discardableResult
    public mutating func update(_ i: Input) -> Alert? {
        guard i.recording else {
            // Paused (or not yet recording): no alert, and the quiet time starts over on resume.
            wasRecording = false
            alert = nil
            micReleasedAt = nil
            return nil
        }
        if !wasRecording { wasRecording = true; quietFrom = max(quietFrom, i.now) }

        var spoke = false
        if i.liveText {
            // A word counts once it ends after the quiet stretch began (a word from before a pause can arrive late).
            if let w = i.lastWordEnd, w > (lastSpeech ?? -1) {
                lastSpeech = w
                if w > quietFrom { quietFrom = w; spoke = true }
            }
        } else if !i.levelsSilent {
            lastSpeech = i.now; quietFrom = i.now; spoke = true
        }
        if spoke {
            // Speech resumed: the alert clears, Keep Recording's silence ends, and the call-ended signal waits for an app
            // to use the microphone again (the call may be over while people keep talking in the room).
            if alert != nil || snoozed { micSeen = false; micReleasedAt = nil }
            alert = nil
            snoozed = false
        }

        switch i.othersUsingMicrophone {
        case true?: micSeen = true; micReleasedAt = nil
        case false?: if micSeen, micReleasedAt == nil { micReleasedAt = i.now }
        case nil: break
        }

        guard alert == nil, !snoozed else { return nil }
        let usedLevels = !i.liveText
        if i.now - quietFrom >= threshold {
            alert = Alert(reason: .quiet, quietSince: quietFrom, usedLevels: usedLevels)
        } else if let released = micReleasedAt, i.now - released >= micReleaseDelay {
            alert = Alert(reason: .callEnded, quietSince: quietFrom, usedLevels: usedLevels)
        }
        return alert
    }

    /// Keep Recording: silence the alert until speech resumes.
    public mutating func keepRecording() {
        guard alert != nil else { return }
        alert = nil
        snoozed = true
        micSeen = false
        micReleasedAt = nil
    }

    /// Where a Stop now should end the meeting: the last speech + `margin`, only while the alert is up, and only when
    /// someone spoke at all and that cuts something off. Nil keeps the whole recording.
    public func trimEnd(duration: Double, margin: Double = 5) -> Double? {
        guard alert != nil, let lastSpeech else { return nil }
        let end = lastSpeech + margin
        return end < duration - 0.5 ? end : nil
    }

    // MARK: Wording

    /// Notification title and body.
    public static func notification(_ a: Alert, now: Double) -> (title: String, body: String) {
        switch a.reason {
        case .quiet: ("Still recording?", "No one has spoken for \(duration(now - a.quietSince)).")
        case .callEnded: ("Still recording?", "The call seems to have ended.")
        }
    }

    /// The strip's amber label: "Quiet 1:12".
    public static func stripLabel(_ a: Alert, now: Double) -> String {
        let s = max(0, Int(now - a.quietSince))
        return String(format: "Quiet %d:%02d", s / 60, s % 60)
    }

    /// "1 min", "2 min", "45 s".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60) min"
    }
}
