#if DEBUG
import AppKit
import SwiftUI
import Capture
import Domain
import DomainFixtures
import Presentation
import Storage

/// T67 check (Debug only): `Amaranth --debug-stop-layout <out.jsonl> [--narrow] [--sidebar-closed] [--prompt]` runs the
/// real main window (the SwiftUI scene, not a hosted copy), on a throwaway library of fixtures, at the screen's full
/// visible height, through Record → Stop → the "Saved …" banner → notes. At each step it logs the window frame and every
/// scroll view's frame, insets and offset, and fails the step when a scroll view reaches outside the window (the bug: both
/// columns taller than the window, their tops off screen). Ends with a `result` line and quits.
/// `scripts/stop-layout.sh` runs every variant.
@MainActor
enum StopLayoutProbe {
    static var outputPath: String? {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--debug-stop-layout").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
    }
    static var isRequested: Bool { outputPath != nil }

    static let store: MeetingStore? = {
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-stop-layout-\(UUID())")
        guard let s = try? MeetingStore(root: root) else { return nil }
        for f in Fixtures.all { try? UIRenderSelfTest.persistFixture(f, s) }
        try? UIRenderSelfTest.persistLongMeeting(s)
        return s
    }()

    static let savedLine = "Saved 1812 segments (3624 s) to /Users/someone/Library/Application Support/Amaranth/meetings/0B6E2D44-1D7F-4A5C-9D8B-3E1F00C0FFEE"

    static func log(_ fields: [String: Any]) {
        guard let path = outputPath, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile(); h?.write(data + Data("\n".utf8)); try? h?.close()
    }

    static func scrollViews(in v: NSView) -> [NSScrollView] {
        (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews)
    }

    static var failed = false

    static func snapshot(_ step: String, _ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        let r: (CGRect) -> String = { "\(Int($0.minX)) \(Int($0.minY)) \(Int($0.width)) \(Int($0.height))" }
        let root = window.contentView?.superview ?? window.contentView!
        let scrolls = scrollViews(in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 60 }.map { s -> [String: String] in
            let inWindow = s.convert(s.bounds, to: nil)
            return ["frame": r(inWindow), "insetTop": "\(Int(s.contentInsets.top))", "insetBottom": "\(Int(s.contentInsets.bottom))",
                    "auto": "\(s.automaticallyAdjustsContentInsets)", "originY": "\(Int(s.contentView.bounds.origin.y))",
                    "doc": "\(Int(s.documentView?.frame.height ?? 0))", "kind": String(describing: type(of: s.documentView ?? s))]
        }
        let height = window.contentView?.bounds.height ?? 0
        let inside = scrollViews(in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 60 }
            .allSatisfy { let f = $0.convert($0.bounds, to: nil); return f.minY >= -0.5 && f.maxY <= height + 0.5 }
        if !inside { failed = true }
        log(["step": step, "ok": "\(inside)", "window": r(window.frame), "visible": r(window.screen?.visibleFrame ?? .zero),
             "layout": r(window.contentLayoutRect), "content": r(window.contentView?.frame ?? .zero),
             "safeTop": "\(Int(window.contentView?.safeAreaInsets.top ?? 0))", "scrolls": scrolls])
        if let dir = outputPath.map({ URL(filePath: $0).deletingLastPathComponent() }) {
            let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "stop-layout-\(step).png"))
        }
    }

    static func run(recorder: RecorderModel, library: LibraryModel) async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        await wait(2)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Amaranth" }) else {
            log(["step": "no-window", "windows": NSApp.windows.map { $0.identifier?.rawValue ?? $0.title }]); NSApp.terminate(nil); return
        }
        UserDefaults.standard.set(true, forKey: "onboarded")
        let args = CommandLine.arguments
        if let visible = window.screen?.visibleFrame {
            let width = args.contains("--narrow") ? 900.0 : 1100.0
            window.setFrame(CGRect(x: visible.minX + 40, y: visible.minY, width: width, height: visible.height), display: true)
        }
        await wait(1)
        if args.contains("--sidebar-closed") {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            await wait(1)
        }
        guard let id = library.items.first(where: { $0.id != MeetingID("ui-long") })?.id ?? library.items.first?.id else {
            log(["step": "no-meetings"]); NSApp.terminate(nil); return
        }
        library.selection = MeetingID("ui-long")
        await wait(1)
        snapshot("0-idle", window)
        let health: [SourceHealth] = [.init(source: .microphone, status: .healthy, peakLevelDBFS: -18, deviceName: "MacBook Pro Microphone"),
                                      .init(source: .systemOutput, status: .healthy, peakLevelDBFS: -24, deviceName: "System audio")]
        let prompt: CalendarSuggestion.Prompt = args.contains("--prompt")
            ? .one(UIRenderSelfTest.longTitleEvent)
            : .none
        recorder.showStripForRender(.recording, health: health, prompt: prompt)
        library.recordingStarted(id)
        await wait(1.5)
        snapshot("1-recording", window)
        recorder.showStripForRender(.stopping, health: health)
        await wait(0.5)
        snapshot("2-stopping", window)
        recorder.showStripForRender(nil)
        library.recordingStopped(id)
        await wait(1.5)
        snapshot("3-stopped", window)
        recorder.setResultForRender(Self.savedLine)
        await wait(1.5)
        snapshot("3b-banner", window)
        library.detailTab = .notes
        await wait(1.5)
        snapshot("4-notes", window)
        log(["result": failed ? "fail" : "pass", "variant": args.filter { $0.hasPrefix("--") && $0 != "--debug-stop-layout" }.joined(separator: " ")])
        NSApp.terminate(nil)
    }
}
#endif
