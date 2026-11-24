public import Foundation

/// Settings → Recording: "Alert when a recording goes quiet" and its threshold (T68).
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

    /// What to do when the call ends (2026-11-02, T122): stop and make notes (default), ask "Still recording?", or ignore
    /// the call signals. Independent of the quiet toggle above. Covers both call signals (see `QuietMonitor`).
    public enum CallEndedAction: String, CaseIterable, Sendable { case stop, ask, off }
    public static let callEndedKey = "callEndedAction"
    public static let callEndedDefault = CallEndedAction.stop
    /// T122: an app must hold the microphone this long before its letting go counts as the call ending (a dictation
    /// shortcut or a sound check is shorter).
    public static let callAppMinHold: Double = 15
    /// How long a call app must have let go before acting: covers switching devices (a quick release and re-acquire).
    /// With a 0.5 s poll, the recording stops under 5 s after the call.
    public static let micReleaseDelay: Double = 3
    /// One-sided: no call audio (the system source) for this long, once the call was under way, ends the call.
    public static let oneSidedDelay: Double = 180
    /// …"under way": a call app held the microphone and the call audio had this many seconds of speech.
    public static let remoteSpeechToArm: Double = 30
    /// …and the one-sided clock starts over while the microphone has this many live words in the last minute (the user
    /// presenting or talking at length; stray words from room noise are far sparser).
    public static let presentingWordsPerMinute = 30

    public static func callEnded(_ d: UserDefaults = .standard) -> CallEndedAction {
        d.string(forKey: callEndedKey).flatMap(CallEndedAction.init(rawValue:)) ?? callEndedDefault
    }

    /// "30 s", "1 min", "2 min"…
    public static func label(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }
}

/// Decides when a recording has gone quiet or the call has ended (T68, T122). Pure: the recorder feeds it one `Input` per
/// tick (session seconds, live words, levels, which other apps use the microphone) and reads `alert`. It never stops
/// anything itself.
///
/// Three signals, any raises the alert:
/// - **Quiet:** no live word on either source for `threshold` seconds. Words, not levels, because hum and music hold a
///   level up. When live text isn't running, every source's level below the silent line counts as quiet instead.
/// - **Call ended:** an app held the microphone for `callAppMinHold` seconds during this recording, then let go for
///   `micReleaseDelay` seconds. Words heard after that don't matter (room noise used to hold the recording open).
/// - **One-sided:** a call app held the microphone and the call audio (system source) had `remoteSpeechToArm` seconds of
///   speech, then the call audio stayed silent for `oneSidedDelay` seconds (the clock starts over while the user talks
///   at length on the microphone). Never armed when the call audio isn't recorded, so recording yourself or starting
///   before the call joins doesn't stop anything.
/// The two call signals let the recorder stop on its own (`readyToStop`, Settings → "When the call ends").
///
/// Paused time never counts. **Keep Recording** silences the quiet signal until speech resumes; the call signals re-arm
/// from scratch (a call app holding the microphone, more call audio).
public struct QuietMonitor: Sendable {
    public enum Reason: Equatable, Sendable { case quiet, callEnded, oneSided }

    public struct Alert: Equatable, Sendable {
        public var reason: Reason
        /// Session seconds of the last speech (or the start / resume, when nobody has spoken since); for a call ending,
        /// when the call app let go; for one-sided, the last call audio (or the user's last long stretch of talking).
        public var quietSince: Double
        /// Live text wasn't running, so levels decided "quiet".
        public var usedLevels: Bool
        public init(reason: Reason, quietSince: Double, usedLevels: Bool) {
            self.reason = reason; self.quietSince = quietSince; self.usedLevels = usedLevels
        }
    }

    /// The call audio (system source); absent when it isn't recorded.
    public struct Remote: Sendable {
        /// End of the newest live word on the system source, in session seconds.
        public var lastWordEnd: Double?
        /// The system source is below the silent level (used when live text isn't running).
        public var levelSilent: Bool
        public init(lastWordEnd: Double?, levelSilent: Bool) { self.lastWordEnd = lastWordEnd; self.levelSilent = levelSilent }
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
        /// The other apps using audio input (bundle ids); nil when unknown.
        public var micUsers: Set<String>?
        /// The call audio; nil when the system source isn't recorded.
        public var remote: Remote?
        /// Live words on the microphone that ended in the last minute.
        public var micWordsLastMinute: Int

        public init(now: Double, recording: Bool, liveText: Bool, lastWordEnd: Double?, levelsSilent: Bool,
                    micUsers: Set<String>? = nil, remote: Remote? = nil, micWordsLastMinute: Int = 0) {
            self.now = now; self.recording = recording; self.liveText = liveText; self.lastWordEnd = lastWordEnd
            self.levelsSilent = levelsSilent; self.micUsers = micUsers; self.remote = remote
            self.micWordsLastMinute = micWordsLastMinute
        }
    }

    public let threshold: Double
    public let micReleaseDelay: Double
    public let callAppMinHold: Double
    public let oneSidedDelay: Double
    public private(set) var alert: Alert?
    /// Session seconds of the last speech heard (a live word's end, or a non-silent level); nil until someone speaks.
    public private(set) var lastSpeech: Double?
    /// What changed in the call signals since the last `drainLog()` (no meeting content: app ids and times only).
    public private(set) var log: [String] = []
    /// Start of the current quiet stretch: the last speech, or when recording (re)started.
    private var quietFrom: Double = 0
    private var wasRecording = false
    private var lastNow: Double?
    private var snoozed = false
    /// Other apps using the microphone now → since when (session seconds).
    private var holdSince: [String: Double] = [:]
    /// Apps that held it for `callAppMinHold`: the call apps.
    private var callApps: Set<String> = []
    /// Call apps not using the microphone now → since when.
    private var leftAt: [String: Double] = [:]
    /// When the call app let go (the call ended), once `micReleaseDelay` has passed.
    private var endedAt: Double?
    /// Seconds of call-audio speech so far (word gaps capped at 3 s).
    private var remoteSpeech: Double = 0
    private var remoteLastEnd: Double?
    /// Start of the current stretch without call audio, once the one-sided signal is armed.
    private var remoteQuietFrom: Double?

    public init(threshold: Double = QuietAlertSettings.defaultThreshold,
                micReleaseDelay: Double = QuietAlertSettings.micReleaseDelay,
                callAppMinHold: Double = QuietAlertSettings.callAppMinHold,
                oneSidedDelay: Double = QuietAlertSettings.oneSidedDelay) {
        self.threshold = threshold
        self.micReleaseDelay = micReleaseDelay
        self.callAppMinHold = callAppMinHold
        self.oneSidedDelay = oneSidedDelay
    }

    /// Feeds one tick. Returns the alert when this tick raised it or changed its reason (to post one notification),
    /// else nil.
    @discardableResult
    public mutating func update(_ i: Input) -> Alert? {
        guard i.recording else {
            // Paused (or not yet recording): no alert, and the quiet time starts over on resume. The call signals re-arm
            // from scratch too: an app that let go while paused isn't a reason to stop right after Resume.
            wasRecording = false
            alert = nil
            lastNow = nil
            holdSince = [:]; callApps = []; leftAt = [:]; endedAt = nil
            // Session time includes the pause, so the one-sided clock would have run through it: start over.
            remoteSpeech = 0; remoteQuietFrom = nil
            return nil
        }
        if !wasRecording { wasRecording = true; quietFrom = max(quietFrom, i.now) }
        let dt = lastNow.map { min(max(i.now - $0, 0), 1) } ?? 0
        lastNow = i.now

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
            // Speech resumed: the quiet alert clears and Keep Recording's silence ends. The call signals don't care.
            if alert?.reason == .quiet { alert = nil }
            snoozed = false
        }

        trackMicrophone(i)
        trackRemote(i, dt: dt)

        let usedLevels = !i.liveText
        let previous = alert
        if let endedAt {
            alert = Alert(reason: .callEnded, quietSince: endedAt, usedLevels: usedLevels)
        } else if !callApps.isEmpty, let from = remoteQuietFrom, i.now - from >= oneSidedDelay {
            alert = Alert(reason: .oneSided, quietSince: from, usedLevels: usedLevels)
        } else if alert?.reason == .callEnded || alert?.reason == .oneSided {
            alert = nil   // the call app came back, or the call audio did
        }
        if alert == nil, !snoozed, i.now - quietFrom >= threshold {
            alert = Alert(reason: .quiet, quietSince: quietFrom, usedLevels: usedLevels)
        }
        if let a = alert, a.reason != previous?.reason {
            if a.reason != .quiet { log.append("\(Int(i.now)) s: alert \(a.reason)") }
            return a
        }
        return nil
    }

    private mutating func trackMicrophone(_ i: Input) {
        guard let users = i.micUsers else { return }
        for u in users {
            if holdSince[u] == nil { holdSince[u] = i.now }
            if let t = leftAt.removeValue(forKey: u) { log.append("\(Int(i.now)) s: \(u) took the microphone back after \(Int(i.now - t)) s") }
        }
        for u in holdSince.keys where !users.contains(u) { holdSince[u] = nil }
        for (u, since) in holdSince where !callApps.contains(u) && i.now - since >= callAppMinHold {
            callApps.insert(u)
            log.append("\(Int(i.now)) s: \(u) has held the microphone \(Int(callAppMinHold)) s (call app)")
        }
        for u in callApps where !users.contains(u) && leftAt[u] == nil {
            leftAt[u] = i.now
            log.append("\(Int(i.now)) s: \(u) let go of the microphone")
        }
        // The earliest call app still away past the grace; nil once they're all back (only reachable while asking).
        let ended = leftAt.values.filter { i.now - $0 >= micReleaseDelay }.min()
        if let ended, endedAt == nil { log.append("\(Int(i.now)) s: call ended at \(Int(ended)) s") }
        endedAt = ended
    }

    private mutating func trackRemote(_ i: Input, dt: Double) {
        guard let r = i.remote else { return }
        var remoteSpokeAt: Double?
        if i.liveText {
            if let w = r.lastWordEnd, w > (remoteLastEnd ?? -1) {
                remoteSpeech += remoteLastEnd.map { min(max(w - $0, 0), 3) } ?? 1
                remoteLastEnd = w
                remoteSpokeAt = w
            }
        } else if !r.levelSilent {
            remoteSpeech += dt
            remoteSpokeAt = i.now
        }
        if remoteQuietFrom == nil {
            guard !callApps.isEmpty, remoteSpeech >= QuietAlertSettings.remoteSpeechToArm else { return }
            remoteQuietFrom = remoteSpokeAt ?? remoteLastEnd ?? i.now
            log.append("\(Int(i.now)) s: one-sided timer armed (\(Int(remoteSpeech)) s of call audio)")
        }
        if let at = remoteSpokeAt { remoteQuietFrom = max(remoteQuietFrom ?? at, at) }
        // The user presenting: the clock starts over at their latest word. Without live text, sound on the microphone
        // does it (room hum can then hold it off: that fallback is rare and errs on the side of not cutting anyone off).
        if i.liveText {
            if i.micWordsLastMinute >= QuietAlertSettings.presentingWordsPerMinute, let w = i.lastWordEnd {
                remoteQuietFrom = max(remoteQuietFrom ?? w, w)
            }
        } else if !i.levelsSilent {
            remoteQuietFrom = max(remoteQuietFrom ?? i.now, i.now)
        }
    }

    /// The call-signal log since the last call (for the recorder's diagnostics line).
    public mutating func drainLog() -> [String] {
        defer { log = [] }
        return log
    }

    /// Keep Recording: silence the alert. The quiet signal waits for speech; the call signals re-arm from scratch (an app
    /// still holding the microphone counts again at once; the one-sided signal needs more call audio).
    public mutating func keepRecording() {
        guard alert != nil else { return }
        snoozed = true   // whatever the reason, the quiet signal waits for speech (else it would ask again at once)
        alert = nil
        callApps = []; leftAt = [:]; endedAt = nil
        remoteSpeech = 0; remoteQuietFrom = nil
        log.append("Keep Recording: call signals re-armed")
    }

    /// "Stop automatically when the call ends": a call signal is up (the call app let go, or the call audio went silent).
    public func readyToStop() -> Bool {
        alert?.reason == .callEnded || alert?.reason == .oneSided
    }

    /// Where a Stop now should end the meeting, only while the alert is up, and only when that cuts something off. Nil
    /// keeps the whole recording.
    /// - quiet: the last speech + `margin` (only when someone spoke at all);
    /// - call ended: when the call app let go + 1 s (or the quiet end, if it had already gone quiet before that);
    /// - one-sided: the last call audio (or the user's last long stretch of talking) + 10 s.
    public func trimEnd(duration: Double, margin: Double = 5) -> Double? {
        guard let alert else { return nil }
        let quietEnd = lastSpeech.map { $0 + margin }
        let end: Double?
        switch alert.reason {
        case .quiet: end = quietEnd
        case .callEnded:
            let wentQuiet = alert.quietSince - quietFrom >= threshold
            end = min(alert.quietSince + 1, wentQuiet ? (quietEnd ?? .infinity) : .infinity)
        case .oneSided: end = alert.quietSince + 10
        }
        guard let end else { return nil }
        return end < duration - 0.5 ? end : nil
    }

    // MARK: Wording

    /// Notification title and body.
    public static func notification(_ a: Alert, now: Double) -> (title: String, body: String) {
        switch a.reason {
        case .quiet: ("Still recording?", "No one has spoken for \(duration(now - a.quietSince)).")
        case .callEnded: ("Still recording?", "The call app stopped using the microphone.")
        case .oneSided: ("Still recording?", "No one else has spoken for \(duration(now - a.quietSince)).")
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
