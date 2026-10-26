import AppKit
import SwiftUI
import Domain
import DomainFixtures
import Storage
import Presentation

/// `Amaranth --self-test ui-render --self-test-output <dir>`: builds the real views over a temporary store (fixture
/// meetings plus a synthetic two-hour meeting), lays them out offscreen, writes PNGs, and reports layout/render times.
/// No audio, no permissions, and nothing touches the user's library. Every screen renders in light and in dark (T43),
/// into `<dir>/light/` and `<dir>/dark/`.
enum UIRenderSelfTest {
    @MainActor static func run(outputDirectory: URL?, textSize: TextSize = .default) async -> Bool {
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
        var ok = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            SelfTest.log(["step": "appearance", "appearance": name])
            let dir = out.appending(path: name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if await !render(store: store, out: dir, textSize: textSize, appearance: NSAppearance(named: appearance)!) { ok = false }
        }
        SelfTest.log(["step": "output", "directory": out.path])
        return ok
    }

    @MainActor static func render(store: MeetingStore, out: URL, textSize: TextSize, appearance: NSAppearance) async -> Bool {
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
        func makeView<V: View>(_ v: V, size: CGSize) -> NSView {
            let view = NSHostingView(rootView: v.textSize(textSize).environment(worker).environment(models).environment(recorder)
                .environment(library).environment(playback).environment(live).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            // Offscreen windows don't draw vibrancy; force an opaque, fixed appearance so captures are readable.
            view.appearance = appearance
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentView = view
            return view
        }
        func capture(_ view: NSView, _ name: String) {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
        }
        func host<V: View>(_ v: V, _ name: String, size: CGSize) async -> Double {
            let view = makeView(v, size: size)
            let t0 = ContinuousClock.now
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))   // let async loads and List cells settle
            view.layoutSubtreeIfNeeded()
            capture(view, name)
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 - 0.6
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
            _ = await host(TranscriptPane(detail: d).environment(\.showDetails, false).environment(\.transcriptStyle, .bubbles), "transcript-bubbles-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(TranscriptPane(detail: d).environment(\.showDetails, true).environment(\.transcriptStyle, .bubbles), "transcript-bubbles-details-\(name)", size: CGSize(width: 900, height: 700))
            let tNotes = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, false).defaultAppStorage(collapsed), "notes-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, true).defaultAppStorage(collapsed), "notes-details-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).defaultAppStorage(expanded), "notes-expanded-\(name)", size: CGSize(width: 900, height: 900))
            _ = await host(RecordingDetailsPane(detail: d), "recording-tab-\(name)", size: CGSize(width: 900, height: 600))
            SelfTest.log(["step": "render", "meeting": item.title, "rows": "\(d.rows.count)", "gaps": "\(d.rows.filter(\.isGap).count)",
                          "unknownSpeakerRows": "\(d.rows.filter { !$0.isGap && $0.assignment == .unknown }.count)",
                          "playback": d.playbackUnavailableReason ?? "available", "notes": "\(d.notesState(notesModelInstalled: true))",
                          "mainSeconds": String(format: "%.2f", tMain), "transcriptSeconds": String(format: "%.2f", tTranscript), "transcriptDetailsSeconds": String(format: "%.2f", tTranscriptDetails),
                          "notesSeconds": String(format: "%.2f", tNotes)])
            if d.rows.count > 1000, max(tTranscript, tTranscriptDetails) > 2.0 { ok = false }
        }
        // Evidence jump (T35): focusing a row mid-way through the two-hour meeting selects that row and scrolls it into
        // view, both when the pane is already showing (focus set later) and when it appears with the focus already set.
        if let long = library.items.first(where: { $0.id == MeetingID("ui-long") }) {
            library.selection = long.id
            for _ in 0..<40 where library.detail?.meeting.id != long.id { try? await Task.sleep(for: .milliseconds(50)) }
            if let d = library.detail {
                let shown = TranscriptRows.skim(d.rows)
                let speech = shown.filter { !$0.isGap }
                for style in TranscriptStyle.allCases {
                for (label, target, focusFirst) in [("while-shown", speech[speech.count / 2], false), ("on-appear", speech[speech.count / 3], true)] {
                    library.focusRowID = focusFirst ? target.id : nil
                    let view = NSHostingView(rootView: TranscriptPane(detail: d).environment(\.showDetails, false).textSize(textSize).environment(\.transcriptStyle, style).environment(library)
                        .environment(playback).frame(width: 900, height: 700).background(Color(nsColor: .windowBackgroundColor)))
                    view.appearance = appearance
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = appearance
                    window.contentView = view
                    try? await Task.sleep(for: .milliseconds(600))
                    if !focusFirst { library.focusRowID = target.id }
                    let table = Self.table(in: view)
                    let index = shown.firstIndex { $0.id == target.id } ?? -1
                    var visible = NSRange(location: 0, length: 0)
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(50))
                        view.layoutSubtreeIfNeeded()
                        visible = table.map { $0.rows(in: $0.visibleRect) } ?? visible
                        if table?.selectedRow == index, NSLocationInRange(index, visible) { break }
                    }
                    let pass = table?.selectedRow == index && NSLocationInRange(index, visible)
                    SelfTest.log(["step": "evidence-jump", "style": style.rawValue, "case": label, "row": target.id, "index": "\(index)", "selected": "\(table?.selectedRow ?? -1)",
                                  "visible": "\(visible.location)..<\(visible.location + visible.length)", "ok": "\(pass)"])
                    if !pass { ok = false }
                    if pass, label == "while-shown", style == .columns {
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "transcript-evidence-jump.png"))
                    }
                    window.contentView = nil
                }
                }
                library.focusRowID = nil
            }
        }
        // Sidebar alone (split-view sidebars use vibrancy that offscreen capture may not draw).
        _ = await host(LibrarySidebar(), "sidebar", size: CGSize(width: 360, height: 760))
        // Toolbar recorder (T31): idle control, this meeting's options, the strip in each state, the banner.
        _ = await host(RecordToolbarControl(model: recorder).padding(), "record-control", size: CGSize(width: 260, height: 60))
        _ = await host(RecordOptionsForm(model: recorder) {}, "record-options", size: CGSize(width: 340, height: 230))
        _ = await host(VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(stripSamples.enumerated()), id: \.offset) { _, s in
                RecordingStripContent(state: s.0, elapsed: 3723, health: s.1, savedUpTo: [.microphone: 3720, .systemOutput: 3700],
                                      diskWarning: s.2, folder: nil, pause: {}, resume: {}, stop: {})
            }
        }.padding(), "recording-strip", size: CGSize(width: 520, height: 360))
        // Health popover content (T34).
        _ = await host(RecordingHealthDetails(health: [
            .init(source: .microphone, status: .healthy, peakLevelDBFS: -18, deviceName: "MacBook Pro Microphone"),
            .init(source: .systemOutput, status: .silent, peakLevelDBFS: -90, deviceName: "System audio"),
        ], savedUpTo: [.microphone: 3720, .systemOutput: 3700], now: 3723, diskWarning: RecorderPresentation.diskWarning(secondsLeft: 900),
           folder: "/Users/example/Library/Application Support/Amaranth/meetings/2026-10-25-m1"), "recording-health", size: CGSize(width: 380, height: 260))
        // Live view (T33): scratchpad closed by default, then open above the transcript.
        _ = await host(LiveTranscriptView(), "live-scratchpad-closed", size: CGSize(width: 900, height: 400))
        // The live view where MainView shows it while recording: the detail column of the split view.
        _ = await host(NavigationSplitView { LibrarySidebar() } detail: {
            LiveTranscriptView().safeAreaInset(edge: .top, spacing: 0) { RecorderBanner(model: recorder) }
        }, "live-in-window", size: CGSize(width: 1200, height: 760))
        recorder.scratchpadOpen = true
        recorder.scratchpad = "Ask Dana about the notarization date"
        _ = await host(LiveTranscriptView(), "live-scratchpad-open", size: CGSize(width: 900, height: 400))
        recorder.scratchpadOpen = false
        recorder.scratchpad = ""
        _ = await host(RecorderBannerContent(items: [
            .init(kind: .error, text: "Could not start recording: example error"),
            .init(kind: .permission, text: "Amaranth isn't allowed to record microphone. Allow it in System Settings → Privacy & Security."),
            .init(kind: .notice, text: RecordingDefaults.missingMicrophoneNotice),
            .init(kind: .recovery, text: "Recovered 1 interrupted recording(s): 3 audio segment(s) restored."),
            .init(kind: .result, text: "Saved 12 segments (62 s) to /Users/example/Library/Application Support/Amaranth/meetings/m1"),
        ], dismiss: { _ in }), "recorder-banner", size: CGSize(width: 900, height: 200))
        // Settings → Recording defaults (T30).
        _ = await host(RecordingSettings(recorder: recorder), "settings-recording", size: CGSize(width: 560, height: 560))
        // Settings → Appearance: transcript style cards, each selected in turn (throwaway defaults, at the Settings size).
        _ = await host(AppearanceSettings().defaultAppStorage(collapsed), "settings-appearance-columns", size: CGSize(width: 560, height: 460))
        collapsed.set(TranscriptStyle.bubbles.rawValue, forKey: TranscriptStyle.key)
        _ = await host(AppearanceSettings().defaultAppStorage(collapsed), "settings-appearance-bubbles", size: CGSize(width: 560, height: 460))
        collapsed.removeObject(forKey: TranscriptStyle.key)
        // Onboarding, the model sheet and the menu-bar menu's items (T43: every screen in both appearances).
        _ = await host(OnboardingView {}, "onboarding", size: CGSize(width: 560, height: 520))
        _ = await host(ModelSetupView(model: models), "model-sheet", size: CGSize(width: 560, height: 460))
        _ = await host(VStack(alignment: .leading, spacing: 6) { MenuBarContent(recorder: recorder) }.padding(), "menu-bar", size: CGSize(width: 260, height: 180))
        // Switching meetings: frames straight after the selection changes, while the next meeting loads.
        if library.items.count >= 2 {
            library.selection = library.items[0].id
            let view = makeView(MainView(), size: CGSize(width: 1200, height: 760))
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            library.selection = library.items[1].id
            for (i, ms) in [0, 20, 60, 200].enumerated() {
                try? await Task.sleep(for: .milliseconds(ms))
                view.layoutSubtreeIfNeeded()
                capture(view, "switch-frame-\(i)")
            }
        }
        // Search renders results.
        library.query = "release"
        SelfTest.log(["step": "search", "query": "release", "hits": "\(library.hits.count)"])
        _ = await host(MainView(), "search", size: CGSize(width: 1200, height: 760))
        library.query = ""
        return ok
    }

    static func table(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for v in view.subviews { if let t = table(in: v) { return t } }
        return nil
    }

    /// Every SourceHealth status appears in at least one strip, plus the low-disk glyph.
    static let stripSamples: [(CaptureState, [SourceHealth], String?)] = [
        (.recording, [.init(source: .microphone, status: .healthy, deviceName: "MacBook Pro Microphone"), .init(source: .systemOutput, status: .silent)], nil),
        (.recording, [.init(source: .microphone, status: .clipping), .init(source: .systemOutput, status: .degraded)],
         RecorderPresentation.diskWarning(secondsLeft: 900)),
        (.paused, [.init(source: .microphone, status: .failed), .init(source: .systemOutput, status: .permissionDenied)], nil),
        (.interrupted, [.init(source: .microphone, status: .starting), .init(source: .systemOutput, status: .inactive)], nil),
        (.preparing, [], nil),
        (.stopping, [.init(source: .microphone, status: .healthy)], nil),
    ]

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
