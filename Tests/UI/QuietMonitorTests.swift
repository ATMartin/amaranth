import Foundation
import Testing
import Presentation

/// T68 table tests: a fake clock fed one tick per second.
@Suite("Quiet alert")
struct QuietMonitorTests {
    typealias Input = QuietMonitor.Input

    /// Runs ticks from `from` to `to` (inclusive, 1 s apart) with `make(t)` and returns the alerts raised, by time.
    @discardableResult
    func run(_ m: inout QuietMonitor, _ from: Int, _ to: Int, _ make: (Double) -> Input) -> [Double: QuietMonitor.Alert] {
        var raised: [Double: QuietMonitor.Alert] = [:]
        for t in from...to { if let a = m.update(make(Double(t))) { raised[Double(t)] = a } }
        return raised
    }

    static let chrome = "com.google.Chrome.helper"

    /// `mic`: true = the call app (Chrome) holds the microphone, false = no other app does, nil = unknown.
    func live(_ t: Double, word: Double?, recording: Bool = true, mic: Bool? = nil) -> Input {
        Input(now: t, recording: recording, liveText: true, lastWordEnd: word, levelsSilent: true,
              micUsers: mic.map { $0 ? [Self.chrome] : [] })
    }

    /// T122 one-sided ticks: `remoteWord` is the call audio's newest word end; `micWords` the mic's words in the last minute.
    func call(_ t: Double, word: Double?, users: Set<String>? = [chrome], remoteWord: Double?, micWords: Int = 0) -> Input {
        Input(now: t, recording: true, liveText: true, lastWordEnd: max(word ?? -1, remoteWord ?? -1) < 0 ? nil : max(word ?? -1, remoteWord ?? -1),
              levelsSilent: true, micUsers: users, remote: .init(lastWordEnd: remoteWord, levelSilent: true), micWordsLastMinute: micWords)
    }

    @Test func alertsAtTheThresholdNotBefore() {
        var m = QuietMonitor(threshold: 60)
        // Last word ends at 10 s: 59 s later nothing, 60 s later the alert.
        #expect(run(&m, 0, 69) { live($0, word: $0 >= 10 ? 10 : nil) }.isEmpty)
        #expect(m.alert == nil)
        let raised = run(&m, 70, 75) { live($0, word: 10) }
        #expect(raised.keys.sorted() == [70], "raised once, at 60 s of quiet")
        #expect(m.alert == .init(reason: .quiet, quietSince: 10, usedLevels: false))
        #expect(QuietMonitor.stripLabel(m.alert!, now: 82) == "Quiet 1:12")
        #expect(QuietMonitor.notification(m.alert!, now: 70).body == "No one has spoken for 1 min.")
    }

    @Test func noSpeechAtAllCountsFromTheStart() {
        var m = QuietMonitor(threshold: 30)
        let raised = run(&m, 0, 40) { live($0, word: nil) }
        #expect(raised.keys.sorted() == [30])
        #expect(m.trimEnd(duration: 40) == nil, "nobody spoke: never trim the whole meeting away")
    }

    @Test func oneSideTalkingHoldsItOff() {
        // Words from either source update the newest word end; one quiet side alone never alerts.
        var m = QuietMonitor(threshold: 60)
        #expect(run(&m, 0, 300) { live($0, word: max(0, $0 - 3)) }.isEmpty)
    }

    @Test func speechResumingClearsTheAlert() {
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 70) { live($0, word: 5) }
        #expect(m.alert != nil)
        _ = m.update(live(71, word: 70.5))
        #expect(m.alert == nil, "a new word clears it")
        #expect(run(&m, 72, 129) { live($0, word: 70.5) }.isEmpty)
        #expect(run(&m, 130, 131) { live($0, word: 70.5) }.keys.sorted() == [131], "re-armed: 60 s after the new word")
    }

    @Test func keepRecordingSilencesUntilSpeechResumes() {
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 61) { live($0, word: 1) }
        #expect(m.alert != nil)
        m.keepRecording()
        #expect(m.alert == nil)
        #expect(run(&m, 62, 600) { live($0, word: 1) }.isEmpty, "stays silent however long it stays quiet")
        _ = m.update(live(601, word: 600))
        #expect(run(&m, 602, 661) { live($0, word: 600) }.keys.sorted() == [660], "speech re-arms it")
    }

    @Test func pausedNeverAlertsAndPauseTimeDoesNotCount() {
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 30) { live($0, word: 0.5) }
        #expect(run(&m, 31, 500) { live($0, word: 0.5, recording: false) }.isEmpty, "paused: never")
        // Resumed at 501: the quiet time starts again there.
        #expect(run(&m, 501, 560) { live($0, word: 0.5) }.isEmpty)
        #expect(run(&m, 561, 561) { live($0, word: 0.5) }.keys.sorted() == [561])
        // Pausing while the alert is up takes it down.
        _ = m.update(live(562, word: 0.5, recording: false))
        #expect(m.alert == nil)
    }

    @Test func levelsDecideWhenLiveTextIsOff() {
        var m = QuietMonitor(threshold: 60)
        func level(_ t: Double, silent: Bool) -> Input {
            Input(now: t, recording: true, liveText: false, lastWordEnd: nil, levelsSilent: silent)
        }
        #expect(run(&m, 0, 100) { level($0, silent: $0 > 100) }.isEmpty, "sound holds it off")
        let raised = run(&m, 101, 161) { level($0, silent: true) }
        #expect(raised.keys.sorted() == [160])
        #expect(m.alert?.usedLevels == true, "the fallback is visible in the diagnostics")
        #expect(m.trimEnd(duration: 161) == 105, "last sound + 5 s")
    }

    // T122 (2026-11-23): the call app letting go of the microphone ends the call, under 5 s, whatever the room says.

    @Test func stopsWithinFiveSecondsOfTheCallAppLettingGo() {
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 99) { live($0, word: $0 - 0.5, mic: true) }
        #expect(m.alert == nil && !m.readyToStop())
        // Chrome lets go at 100; room noise keeps producing words: the alert at 103 (3 s grace), ready to stop at once.
        let raised = run(&m, 100, 104) { live($0, word: $0 - 0.5, mic: false) }
        #expect(raised.keys.sorted() == [103])
        #expect(m.alert == .init(reason: .callEnded, quietSince: 100, usedLevels: false))
        #expect(m.readyToStop())
        #expect(m.trimEnd(duration: 104) == 101, "ends 1 s after the call app let go")
        #expect(QuietMonitor.notification(m.alert!, now: 103).body == "The call app stopped using the microphone.")
    }

    @Test func roomWordsAfterTheCallDontCancelIt() {
        // The 2026-11-23 bug: stray words after the call cleared the alert and disarmed the signal for good.
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 99) { live($0, word: $0, mic: true) }
        run(&m, 100, 103) { live($0, word: $0, mic: false) }
        #expect(m.alert?.reason == .callEnded)
        run(&m, 104, 600) { live($0, word: $0 - 0.2, mic: false) }
        #expect(m.alert?.reason == .callEnded && m.readyToStop(), "still asking (Ask setting), still ready to stop")
    }

    @Test func aShortHoldIsNotACall() {
        // A dictation shortcut or a sound check: 10 s, then let go.
        var m = QuietMonitor(threshold: 600)
        run(&m, 0, 20) { live($0, word: $0, mic: false) }
        run(&m, 21, 30) { live($0, word: $0, mic: true) }
        #expect(run(&m, 31, 300) { live($0, word: $0, mic: false) }.isEmpty)
    }

    @Test func aBriefReleaseDoesNothing() {
        // Switching devices: let go for 2 s, then back.
        var m = QuietMonitor(threshold: 600)
        run(&m, 0, 50) { live($0, word: 5, mic: true) }
        run(&m, 51, 52) { live($0, word: 5, mic: false) }
        #expect(run(&m, 53, 300) { live($0, word: 5, mic: true) }.isEmpty)
        #expect(!m.readyToStop())
    }

    @Test func anotherAppStillHoldingTheMicDoesntMaskTheCallApp() {
        // A dictation tool that always listens holds the mic the whole time; Chrome's leaving still ends the call.
        var m = QuietMonitor(threshold: 600)
        let dictation = "com.example.dictation"
        func at(_ t: Double, _ users: Set<String>) -> Input {
            Input(now: t, recording: true, liveText: true, lastWordEnd: t, levelsSilent: true, micUsers: users)
        }
        run(&m, 0, 99) { at($0, [Self.chrome, dictation]) }
        #expect(run(&m, 100, 105) { at($0, [dictation]) }.keys.sorted() == [103])
        #expect(m.readyToStop())
    }

    @Test func microphoneNeverUsedHeldOrUnknownNeverAlerts() {
        var m = QuietMonitor(threshold: 600)
        #expect(run(&m, 0, 300) { live($0, word: $0, mic: false) }.isEmpty, "no app ever used the mic: no signal")
        var held = QuietMonitor(threshold: 600)
        #expect(run(&held, 0, 300) { live($0, word: $0, mic: true) }.isEmpty, "held: no signal")
        var unknown = QuietMonitor(threshold: 600)
        run(&unknown, 0, 30) { live($0, word: $0, mic: true) }
        #expect(run(&unknown, 31, 300) { live($0, word: $0, mic: nil) }.isEmpty, "unknown is not 'let go'")
    }

    @Test func callAppComingBackWhileAskingClearsIt() {
        var m = QuietMonitor(threshold: 600)
        run(&m, 0, 30) { live($0, word: $0, mic: true) }
        run(&m, 31, 34) { live($0, word: $0, mic: false) }
        #expect(m.alert?.reason == .callEnded)
        _ = m.update(live(35, word: 35, mic: true))
        #expect(m.alert == nil && !m.readyToStop(), "rejoined the call")
    }

    @Test func keepRecordingAfterCallEndedWaitsForANewCall() {
        var m = QuietMonitor(threshold: 600)
        run(&m, 0, 30) { live($0, word: $0, mic: true) }
        run(&m, 31, 34) { live($0, word: $0, mic: false) }
        #expect(m.alert?.reason == .callEnded)
        m.keepRecording()
        #expect(m.alert == nil)
        #expect(run(&m, 35, 200) { live($0, word: $0, mic: false) }.isEmpty, "still let go: no repeat")
        run(&m, 201, 220) { live($0, word: $0, mic: true) }
        #expect(run(&m, 221, 225) { live($0, word: $0, mic: false) }.keys.sorted() == [224], "a new call's end alerts again")
    }

    @Test func pausingRearmsTheCallSignal() {
        // Let go while paused: Resume isn't followed by an instant stop.
        var m = QuietMonitor(threshold: 600)
        run(&m, 0, 30) { live($0, word: $0, mic: true) }
        run(&m, 31, 60) { live($0, word: $0, recording: false, mic: false) }
        #expect(run(&m, 61, 300) { live($0, word: $0, mic: false) }.isEmpty)
    }

    @Test func alreadyQuietThenTheCallEnds() {
        var m = QuietMonitor(threshold: 30)
        run(&m, 0, 40) { live($0, word: 2, mic: true) }
        #expect(m.alert?.reason == .quiet)
        #expect(!m.readyToStop(), "quiet alone only asks")
        #expect(run(&m, 41, 44) { live($0, word: 2, mic: false) }.keys.sorted() == [44], "becomes the call ending")
        #expect(m.alert?.reason == .callEnded && m.readyToStop())
        #expect(m.trimEnd(duration: 44) == 7, "it had gone quiet before the call ended: the last words + 5 s")
    }

    @Test func callEndedWithoutTheQuietAlert() {
        // Quiet alert off: the recorder passes an infinite threshold.
        var m = QuietMonitor(threshold: .infinity)
        #expect(run(&m, 0, 1000) { live($0, word: 1, mic: true) }.isEmpty)
        #expect(run(&m, 1001, 1004) { live($0, word: 1, mic: false) }.keys.sorted() == [1004])
        #expect(m.readyToStop())
        #expect(m.trimEnd(duration: 1004) == 1002)
    }

    // T122: one-sided — the call app keeps the microphone but the call audio has gone silent.

    @Test func oneSidedStopsAfterThreeMinutesWithoutCallAudio() {
        var m = QuietMonitor(threshold: .infinity)
        // Others talk until 60 (armed: 30 s of call audio), then only room noise on the mic (sparse words).
        run(&m, 0, 60) { call($0, word: nil, remoteWord: $0 - 0.5) }
        let raised = run(&m, 61, 300) { call($0, word: $0 - 0.5, remoteWord: 59.5, micWords: 5) }
        #expect(raised.keys.sorted() == [240])
        #expect(m.alert == .init(reason: .oneSided, quietSince: 59.5, usedLevels: false))
        #expect(m.readyToStop())
        #expect(m.trimEnd(duration: 300) == 69.5, "the last call audio + 10 s")
        #expect(QuietMonitor.notification(m.alert!, now: 240).body == "No one else has spoken for 3 min.")
    }

    @Test func oneSidedNeedsSustainedCallAudioFirst() {
        // Waiting in a lobby or recording yourself with the call app open: a few seconds of call audio isn't a call.
        var m = QuietMonitor(threshold: .infinity)
        run(&m, 0, 10) { call($0, word: $0, remoteWord: $0 - 0.5) }
        #expect(run(&m, 11, 1000) { call($0, word: $0, remoteWord: 9.5) }.isEmpty)
    }

    @Test func oneSidedNeedsACallApp() {
        // A video playing (call audio) with no app on the microphone, then silence: not a call.
        var m = QuietMonitor(threshold: .infinity)
        run(&m, 0, 120) { call($0, word: nil, users: [], remoteWord: $0 - 0.5) }
        #expect(run(&m, 121, 1000) { call($0, word: $0, users: [], remoteWord: 119.5) }.isEmpty)
    }

    @Test func microphoneOnlyNeverGoesOneSided() {
        var m = QuietMonitor(threshold: .infinity)
        #expect(run(&m, 0, 1000) { live($0, word: $0, mic: true) }.isEmpty)
    }

    @Test func presentingHoldsTheClock() {
        var m = QuietMonitor(threshold: .infinity)
        run(&m, 0, 60) { call($0, word: nil, remoteWord: $0 - 0.5) }
        // The user talks at length (40 words a minute) from 61 to 500 while everyone else is muted.
        #expect(run(&m, 61, 500) { call($0, word: $0 - 0.5, remoteWord: 59.5, micWords: 40) }.isEmpty)
        // Then stops: 3 min after their last word.
        let raised = run(&m, 501, 700) { call($0, word: 499.5, remoteWord: 59.5, micWords: 0) }
        #expect(raised.keys.sorted() == [680])
        #expect(m.alert?.reason == .oneSided)
    }

    @Test func callAudioReturningClearsTheOneSidedAsk() {
        var m = QuietMonitor(threshold: .infinity)
        run(&m, 0, 60) { call($0, word: nil, remoteWord: $0 - 0.5) }
        run(&m, 61, 240) { call($0, word: nil, remoteWord: 59.5) }
        #expect(m.alert?.reason == .oneSided)
        _ = m.update(call(241, word: nil, remoteWord: 240.5))
        #expect(m.alert == nil)
    }

    @Test func oneSidedFromLevelsWhenLiveTextIsOff() {
        var m = QuietMonitor(threshold: .infinity)
        func level(_ t: Double, remoteSilent: Bool, micSilent: Bool = true) -> Input {
            Input(now: t, recording: true, liveText: false, lastWordEnd: nil, levelsSilent: remoteSilent && micSilent,
                  micUsers: [Self.chrome], remote: .init(lastWordEnd: nil, levelSilent: remoteSilent))
        }
        run(&m, 0, 60) { level($0, remoteSilent: false) }
        let raised = run(&m, 61, 300) { level($0, remoteSilent: true) }
        #expect(raised.keys.sorted() == [240])
        #expect(m.alert?.usedLevels == true)
        // Sound on the microphone (the user talking, as far as levels can tell) holds the clock.
        var talking = QuietMonitor(threshold: .infinity)
        run(&talking, 0, 60) { level($0, remoteSilent: false) }
        #expect(run(&talking, 61, 600) { level($0, remoteSilent: true, micSilent: false) }.isEmpty)
    }

    @Test func pausingRestartsTheOneSidedClock() {
        // Validator v1 blocker: session time includes the pause, so a 3+ min pause stopped the recording on Resume.
        var m = QuietMonitor(threshold: .infinity)
        run(&m, 0, 60) { call($0, word: nil, remoteWord: $0 - 0.5) }
        run(&m, 61, 100) { call($0, word: nil, remoteWord: 59.5) }
        run(&m, 101, 400) { Input(now: $0, recording: false, liveText: true, lastWordEnd: nil, levelsSilent: true) }
        #expect(run(&m, 401, 1000) { call($0, word: nil, remoteWord: 59.5) }.isEmpty, "not armed again until more call audio")
        #expect(!m.readyToStop())
    }

    @Test func callEndedSettingDefaultsToStop() {
        let d = UserDefaults(suiteName: "call-\(UUID())")!
        #expect(QuietAlertSettings.callEnded(d) == .stop)
        d.set("ask", forKey: QuietAlertSettings.callEndedKey)
        #expect(QuietAlertSettings.callEnded(d) == .ask)
        d.set("bogus", forKey: QuietAlertSettings.callEndedKey)
        #expect(QuietAlertSettings.callEnded(d) == .stop)
    }

    @Test func trimOnlyWhileTheAlertIsUp() {
        var m = QuietMonitor(threshold: 60)
        run(&m, 0, 50) { live($0, word: 12) }
        #expect(m.trimEnd(duration: 50) == nil, "no alert: nothing trimmed")
        run(&m, 51, 80) { live($0, word: 12) }
        #expect(m.trimEnd(duration: 80) == 17, "last word + 5 s")
        m.keepRecording()
        #expect(m.trimEnd(duration: 80) == nil, "kept recording: nothing trimmed")
    }

    @Test func settingsDefaultsAndBounds() {
        let d = UserDefaults(suiteName: "quiet-\(UUID())")!
        #expect(QuietAlertSettings.enabled(d))
        #expect(QuietAlertSettings.threshold(d) == 60)
        d.set(5.0, forKey: QuietAlertSettings.thresholdKey)
        #expect(QuietAlertSettings.threshold(d) == 30)
        d.set(9999.0, forKey: QuietAlertSettings.thresholdKey)
        #expect(QuietAlertSettings.threshold(d) == 300)
        #expect(QuietAlertSettings.choices.map(QuietAlertSettings.label) == ["30 s", "1 min", "2 min", "3 min", "5 min"])
    }
}
