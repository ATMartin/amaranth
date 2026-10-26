import SwiftUI
import AppKit

extension View {
    /// Takes exactly the space offered, top-aligned, so the content's own minimum height (a wrapped banner, a long
    /// header) never becomes the window's minimum height. The panes scroll themselves (transcript and live lists, notes,
    /// the Recording tab's form); wrapping them in another scroll view would make the transcript list lay out every row.
    func fillsOfferedSpace() -> some View {
        GeometryReader { g in
            self.frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
    }

    /// Keeps the hosting window no taller (or wider) than its screen's visible area, so the title bar and the bottom
    /// edge stay reachable for moving and resizing. Applies when the window appears (including a restored frame) and
    /// whenever it moves to another screen or the screen's layout changes.
    func windowFitsScreen() -> some View { background(WindowFitsScreen()) }
}

private struct WindowFitsScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> FittingView { FittingView() }
    func updateNSView(_ nsView: FittingView, context: Context) {}

    final class FittingView: NSView {
        private var observers: [NSObjectProtocol] = []

        /// Observers are removed when the view leaves its window (called with a nil window), so no deinit is needed.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: name == NSWindow.didChangeScreenNotification ? window : nil,
                                                                        queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { window.map(Self.fit) }
                })
            }
            // After SwiftUI and state restoration have set the initial frame.
            DispatchQueue.main.async { [weak window] in window.map(Self.fit) }
        }

        static func fit(_ window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame, !window.styleMask.contains(.fullScreen) else { return }
            var frame = window.frame
            frame.size.height = min(frame.height, visible.height)
            frame.size.width = min(frame.width, visible.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
    }
}
