import Foundation
import Testing
import Presentation

/// T68 table tests (docs/decisions/capture/0002): a fake clock fed one tick per second.
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

    func live(_ t: Double, word: Double?, recording: Bool = true, mic: Bool? = nil) -> Input {
        Input(now: t, recording: recording, liveText: true, lastWordEnd: word, levelsSilent: true, othersUsingMicrophone: mic)
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
            Input(now: t, recording: true, liveText: false, lastWordEnd: nil, levelsSilent: silent, othersUsingMicrophone: nil)
        }
        #expect(run(&m, 0, 100) { level($0, silent: $0 > 100) }.isEmpty, "sound holds it off")
        let raised = run(&m, 101, 161) { level($0, silent: true) }
        #expect(raised.keys.sorted() == [160])
        #expect(m.alert?.usedLevels == true, "the fallback is visible in the diagnostics")
        #expect(m.trimEnd(duration: 161) == 105, "last sound + 5 s")
    }

    @Test func microphoneReleasedAfterUse() {
        var m = QuietMonitor(threshold: 600, micReleaseDelay: 30)
        // Music keeps "words" away? No: here someone keeps talking (words), but the call app let go of the mic at 100.
        run(&m, 0, 99) { live($0, word: 0, mic: true) }
        let raised = run(&m, 100, 140) { live($0, word: 0, mic: false) }
        #expect(raised.keys.sorted() == [130])
        #expect(m.alert?.reason == .callEnded)
        #expect(QuietMonitor.notification(m.alert!, now: 130).body == "The call seems to have ended.")
    }

    @Test func microphoneNeverUsedOrHeldNeverAlerts() {
        var m = QuietMonitor(threshold: 600, micReleaseDelay: 30)
        #expect(run(&m, 0, 300) { live($0, word: $0, mic: false) }.isEmpty, "no app ever used the mic: no signal")
        var held = QuietMonitor(threshold: 600, micReleaseDelay: 30)
        #expect(run(&held, 0, 300) { live($0, word: $0, mic: true) }.isEmpty, "held: no signal (the quiet signal is the backstop)")
        var unknown = QuietMonitor(threshold: 600, micReleaseDelay: 30)
        run(&unknown, 0, 10) { live($0, word: $0, mic: true) }
        #expect(run(&unknown, 11, 300) { live($0, word: $0, mic: nil) }.isEmpty, "unknown is not 'released'")
    }

    @Test func keepRecordingAfterCallEndedWaitsForTheMicAgain() {
        var m = QuietMonitor(threshold: 600, micReleaseDelay: 30)
        run(&m, 0, 9) { live($0, word: $0, mic: true) }
        run(&m, 10, 40) { live($0, word: $0, mic: false) }
        #expect(m.alert?.reason == .callEnded)
        m.keepRecording()
        #expect(run(&m, 41, 200) { live($0, word: $0, mic: false) }.isEmpty, "still released: no repeat")
        run(&m, 201, 210) { live($0, word: $0, mic: true) }
        #expect(run(&m, 211, 241) { live($0, word: $0, mic: false) }.keys.sorted() == [241], "a new call's release alerts again")
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
