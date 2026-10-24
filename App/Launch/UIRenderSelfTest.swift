import AppKit
import SwiftUI
import Domain
import DomainFixtures
import Storage
import Presentation

/// `Amaranth --self-test ui-render --self-test-output <dir>`: builds the real views over a temporary store (fixture
/// meetings plus a synthetic two-hour meeting), lays them out offscreen, writes PNGs, and reports layout/render times.
/// No audio, no permissions, and nothing touches the user's library.
enum UIRenderSelfTest {
    @MainActor static func run(outputDirectory: URL?) async -> Bool {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = outputDirectory ?? root.appending(path: "png")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let store = try? MeetingStore(root: root) else { SelfTest.log(["step": "store", "ok": "false"]); return false }
        do {
            for f in Fixtures.all { try persistFixture(f, store) }
            try persistLongMeeting(store)
        } catch { SelfTest.log(["step": "fixtures", "error": "\(error)"]); return false }

        let worker = WorkerClient()
        let models = ModelSetupModel()
        let recorder = RecorderModel(store: store, recover: false)
        let library = LibraryModel(store: store)
        let playback = PlaybackModel()
        let live = LiveTextModel(client: worker)
        UserDefaults.standard.set(true, forKey: "onboarded")
        // Editors expanded (T24) without touching the user's own expansion preferences.
        let expandedSuite = "amaranth-ui-render-\(UUID())"
        let expanded = UserDefaults(suiteName: expandedSuite)!
        expanded.set(true, forKey: "notesUserNotesExpanded"); expanded.set(true, forKey: "notesScratchpadExpanded")
        let collapsedSuite = "amaranth-ui-render-\(UUID())"
        let collapsed = UserDefaults(suiteName: collapsedSuite)!   // empty: every preference at its default
        defer { for s in [expandedSuite, collapsedSuite] { UserDefaults.standard.removePersistentDomain(forName: s) } }
        var ok = true
        func host<V: View>(_ v: V, _ name: String, size: CGSize) async -> Double {
            let view = NSHostingView(rootView: v.environment(worker).environment(models).environment(recorder)
                .environment(library).environment(playback).environment(live).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            // Offscreen windows don't draw vibrancy; force an opaque, fixed appearance so captures are readable.
            view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentView = view
            let t0 = ContinuousClock.now
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))   // let async loads and List cells settle
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let d = ContinuousClock.now - t0
            let secs = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 - 0.6
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
            return secs
        }
        // Library + each fixture meeting's detail views.
        library.reload()
        try? await Task.sleep(for: .milliseconds(500))
        SelfTest.log(["step": "library", "meetings": "\(library.items.count)"])
        for item in library.items {
            library.selection = item.id
            for _ in 0..<40 where library.detail?.meeting.id != item.id { try? await Task.sleep(for: .milliseconds(50)) }
            guard let d = library.detail else { ok = false; SelfTest.log(["step": "detail", "meeting": item.title, "ok": "false"]); continue }
            let name = item.title.replacingOccurrences(of: " ", with: "-")
            let tMain = await host(MainView(), "main-\(name)", size: CGSize(width: 1200, height: 760))
            let tTranscript = await host(TranscriptPane(detail: d).environment(\.showDetails, false), "transcript-\(name)", size: CGSize(width: 900, height: 700))
            let tTranscriptDetails = await host(TranscriptPane(detail: d).environment(\.showDetails, true), "transcript-details-\(name)", size: CGSize(width: 900, height: 700))
            let tNotes = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, false).defaultAppStorage(collapsed), "notes-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, true).defaultAppStorage(collapsed), "notes-details-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).defaultAppStorage(expanded), "notes-expanded-\(name)", size: CGSize(width: 900, height: 900))
            SelfTest.log(["step": "render", "meeting": item.title, "rows": "\(d.rows.count)", "gaps": "\(d.rows.filter(\.isGap).count)",
                          "unknownSpeakerRows": "\(d.rows.filter { !$0.isGap && $0.assignment == .unknown }.count)",
                          "playback": d.playbackUnavailableReason ?? "available", "notes": "\(d.notesState(notesModelInstalled: true))",
                          "mainSeconds": String(format: "%.2f", tMain), "transcriptSeconds": String(format: "%.2f", tTranscript), "transcriptDetailsSeconds": String(format: "%.2f", tTranscriptDetails),
                          "notesSeconds": String(format: "%.2f", tNotes)])
            if d.rows.count > 1000, max(tTranscript, tTranscriptDetails) > 2.0 { ok = false }
        }
        // Sidebar alone (split-view sidebars use vibrancy that offscreen capture may not draw).
        _ = await host(VStack(spacing: 0) { RecorderPanel(model: recorder).padding(8); LibrarySidebar() }, "sidebar", size: CGSize(width: 360, height: 760))
        // Search renders results.
        library.query = "release"
        SelfTest.log(["step": "search", "query": "release", "hits": "\(library.hits.count)"])
        _ = await host(MainView(), "search", size: CGSize(width: 1200, height: 760))
        SelfTest.log(["step": "output", "directory": out.path])
        return ok
    }

    static func persistFixture(_ f: FixtureMeeting, _ store: MeetingStore) throws {
        try store.upsertMeeting(f.meeting)
        try store.insertEpochs(f.epochs)
        try store.insertSegments(f.audioSegments)
        try store.insertEvents(f.events)
        if let t = f.transcript { try store.publishTranscript(t) }
        for e in f.edits { try store.appendEdit(e) }
        if let s = f.summary { try store.publishSummary(s) }
        for j in f.jobs { try store.upsertJob(j) }
    }

    /// Two hours, four speakers, mixed sources, a failed region and an unknown-speaker word per segment.
    static func persistLongMeeting(_ store: MeetingStore) throws {
        let m = MeetingID("ui-long")
        let speakers = (1...4).map { Speaker(id: SpeakerID("long-s\($0)"), label: "Speaker \($0)") }
        var segs: [TranscriptSegment] = []
        for i in 0..<1800 {
            let t0 = Double(i) * 4
            let source: SourceKind = i % 3 == 0 ? .microphone : .systemOutput
            var words: [Word] = []
            for j in 0..<24 {
                let a = t0 + Double(j) * 0.14
                let who: SpeakerAssignment = j == 23 ? .unknown : .speaker(speakers[i % 4].id)
                words.append(Word(id: WordID("l\(i)-\(j)"), text: j == 5 ? "release" : "word\(j)", interval: .seconds(a, a + 0.12), source: source, speaker: who))
            }
            segs.append(TranscriptSegment(id: TranscriptSegmentID("ls\(i)"), source: source, interval: .seconds(t0, t0 + 3.4), words: words, speaker: .speaker(speakers[i % 4].id)))
        }
        try store.upsertMeeting(Meeting(id: m, title: "Two-hour planning session", createdAt: Date(), captureState: .captured, duration: .seconds(7200)))
        let t = TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: Date(), producer: ProducerInfo(component: "ui", configHash: "ui"),
                                   segments: segs, coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 3000), status: .transcribed),
                                                              CoverageRegion(source: .systemOutput, interval: .seconds(3000, 3040), status: .failed),
                                                              CoverageRegion(source: .systemOutput, interval: .seconds(3040, 7200), status: .transcribed)],
                                   speakers: speakers)
        try store.publishTranscript(t)
    }
}
