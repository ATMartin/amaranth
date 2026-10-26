import Testing
import Foundation
import Domain
@testable import Presentation

@Suite("Recording defaults")
struct RecordingDefaultsTests {
    /// The keys predate T30 and hold users' saved choices: renaming them would silently reset them.
    @Test func keysAndDefaultArePinned() {
        #expect(RecordingDefaults.sourcesKey == "defaultSources")
        #expect(RecordingDefaults.microphoneKey == "microphoneUID")
        #expect(RecordingDefaults.sourcesDefault == .both)
    }

    @Test func readsSavedDefaults() throws {
        let d = try #require(UserDefaults(suiteName: "RecordingDefaultsTests-\(UUID())"))
        #expect(RecordingDefaults.sources(d) == .both)
        #expect(RecordingDefaults.microphone(d) == nil)
        d.set(SourceSelection.microphoneOnly.rawValue, forKey: RecordingDefaults.sourcesKey)
        d.set("usb-mic", forKey: RecordingDefaults.microphoneKey)
        #expect(RecordingDefaults.sources(d) == .microphoneOnly)
        #expect(RecordingDefaults.microphone(d) == "usb-mic")
        d.set("garbage", forKey: RecordingDefaults.sourcesKey)
        #expect(RecordingDefaults.sources(d) == .both)
    }

    @Test func presentMicrophoneIsUsed() {
        let r = RecordingDefaults.resolveMicrophone("usb-mic", sources: .both, connected: ["built-in", "usb-mic"])
        #expect(r.uid == "usb-mic")
        #expect(r.notice == nil)
    }

    @Test func missingMicrophoneFallsBackToSystemDefaultWithNotice() {
        let r = RecordingDefaults.resolveMicrophone("usb-mic", sources: .microphoneOnly, connected: ["built-in"])
        #expect(r.uid == nil)
        #expect(r.notice == RecordingDefaults.missingMicrophoneNotice)
    }

    @Test func systemDefaultAndSystemOnlyNeverWarn() {
        #expect(RecordingDefaults.resolveMicrophone(nil, sources: .both, connected: []) == (nil, nil))
        #expect(RecordingDefaults.resolveMicrophone("usb-mic", sources: .systemOnly, connected: []).notice == nil)
    }
}
