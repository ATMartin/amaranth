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
        #expect(RecordingDefaults.folderKey == "defaultFolderID")
    }

    /// T42: the default folder is read by ID and dropped once that folder is deleted.
    @Test func defaultFolder() throws {
        let d = try #require(UserDefaults(suiteName: "RecordingDefaultsTests-\(UUID())"))
        #expect(RecordingDefaults.folder(d) == nil)
        d.set("f1", forKey: RecordingDefaults.folderKey)
        #expect(RecordingDefaults.folder(d) == FolderID("f1"))
        let folders = [Folder(id: FolderID("f1"), name: "Acme")]
        #expect(RecordingDefaults.resolveFolder(FolderID("f1"), folders: folders) == FolderID("f1"))
        #expect(RecordingDefaults.resolveFolder(FolderID("gone"), folders: folders) == nil)
        #expect(RecordingDefaults.resolveFolder(nil, folders: folders) == nil)
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
