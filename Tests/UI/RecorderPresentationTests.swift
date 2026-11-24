import Testing
import Foundation
import Domain
@testable import Presentation

@Suite("Recorder presentation")
struct RecorderPresentationTests {
    /// T31: every SourceHealth status has a glyph colour; green = OK, grey = silent, orange = degraded, red = failed.
    @Test func everyStatusHasATone() {
        let expected: [SourceHealth.Status: RecorderPresentation.Tone] = [
            .healthy: .green, .silent: .grey, .starting: .grey, .inactive: .grey,
            .clipping: .orange, .degraded: .orange, .failed: .red, .permissionDenied: .red,
        ]
        for (s, tone) in expected { #expect(RecorderPresentation.tone(s) == tone, "\(s)") }
        #expect(expected.count == 8)
    }

    @Test func statusTextFlagsDelayedSaving() {
        #expect(RecorderPresentation.statusText(.healthy, savedUpTo: 100, now: 104) == "OK")
        #expect(RecorderPresentation.statusText(.healthy, savedUpTo: 100, now: 120) == "OK · saving delayed")
        #expect(RecorderPresentation.statusText(.permissionDenied, savedUpTo: nil, now: 5) == "Permission denied — see System Settings")
    }

    @Test func tooltipNamesSourceDeviceAndSavedTime() {
        let h = SourceHealth(source: .microphone, status: .healthy, deviceName: "USB Mic")
        #expect(RecorderPresentation.tooltip(h, savedUpTo: 3723, now: 3725) == "Microphone: OK · USB Mic · Saved up to 01:02:03")
        let s = SourceHealth(source: .systemOutput, status: .silent)
        #expect(RecorderPresentation.tooltip(s, savedUpTo: nil, now: 0) == "System audio: Silent (still recording)")
    }

    @Test func automaticTitleUsesDateAndTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-23T10:01:00Z"))
        let title = RecorderPresentation.automaticTitle(date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(title.hasPrefix("Meeting — Oct 23, 2026 10:01"))
        #expect(RecorderPresentation.recordingTitle(typed: "  Standup ", at: date) == "Standup")
        #expect(RecorderPresentation.recordingTitle(typed: "  ", at: date).hasPrefix("Meeting — "))
    }
}
