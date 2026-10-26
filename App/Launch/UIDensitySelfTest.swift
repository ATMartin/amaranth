import AppKit
import SwiftUI
import Domain
import DomainFixtures
import Storage
import Presentation

/// `Amaranth --self-test ui-density --store-root <dir> --meeting <id> --png-dir <dir> [--text-size smaller|default|larger]`:
/// renders one meeting's Transcript and Notes tabs in the main window at 1280×826 and logs how many transcript rows are
/// visible (T36 density check). `--store-root` must be a *copy* of a data directory (scripts/ui-density.sh makes one
/// with sqlite's backup command); without it, the ui-render fixtures and the synthetic two-hour meeting are used.
enum UIDensitySelfTest {
    static let size = CGSize(width: 1280, height: 826)

    @MainActor static func run(args: [String]) async -> Bool {
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        _ = NSApplication.shared
        let temp = FileManager.default.temporaryDirectory.appending(path: "amaranth-density-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = arg("--store-root").map { URL(filePath: $0) } ?? temp
        let out = URL(filePath: arg("--png-dir") ?? temp.appending(path: "png").path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let store = try? MeetingStore(root: root) else { SelfTest.log(["step": "store", "ok": "false"]); return false }
        if arg("--store-root") == nil {
            do { for f in Fixtures.all { try UIRenderSelfTest.persistFixture(f, store) }; try UIRenderSelfTest.persistLongMeeting(store) } catch { SelfTest.log(["step": "fixtures", "error": "\(error)"]); return false }
        }
        let meetingID = MeetingID(arg("--meeting") ?? "ui-long")
        let worker = WorkerClient()
        let models = ModelSetupModel()
        let recorder = RecorderModel(store: store, recover: false)
        let library = LibraryModel(store: store)
        let playback = PlaybackModel()
        let live = LiveTextModel(client: worker)
        library.reload()
        try? await Task.sleep(for: .milliseconds(500))
        library.selection = meetingID
        for _ in 0..<60 where library.detail?.meeting.id != meetingID { try? await Task.sleep(for: .milliseconds(50)) }
        guard let d = library.detail else { SelfTest.log(["step": "detail", "meeting": meetingID.rawValue, "ok": "false"]); return false }
        let label = arg("--label") ?? "run"
        var ok = true
        for tab in [LibraryModel.DetailTab.transcript, .notes] {
            library.detailTab = tab
            let view = NSHostingView(rootView: textSized(MainView(), arg("--text-size")).environment(worker).environment(models).environment(recorder)
                .environment(library).environment(playback).environment(live).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentView = view
            try? await Task.sleep(for: .milliseconds(800))
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(label)-\(tab.rawValue.lowercased()).png"))
            if tab == .transcript {
                let shown = TranscriptRows.skim(d.rows)
                // The transcript table is the one holding exactly the displayed rows (the sidebar is a table too).
                guard let table = tables(in: view).first(where: { $0.numberOfRows == shown.count }) else {
                    SelfTest.log(["step": "transcript-table", "ok": "false"]); ok = false; continue
                }
                let visible = table.rows(in: table.visibleRect)
                let full = (visible.location..<(visible.location + visible.length)).filter { table.visibleRect.contains(table.rect(ofRow: $0)) }
                SelfTest.log(["step": "density", "label": label, "textSize": arg("--text-size") ?? "unset", "rows": "\(shown.count)",
                              "visibleRows": "\(visible.length)", "fullyVisibleRows": "\(full.count)",
                              "visibleSpeechRows": "\(full.filter { !shown[$0].isGap }.count)", "tableHeight": "\(Int(table.visibleRect.height))"])
            }
            window.contentView = nil
        }
        return ok
    }

    @MainActor static func textSized<V: View>(_ v: V, _ size: String?) -> some View { v.textSize(TextSize(stored: size)) }

    static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
    }
}
