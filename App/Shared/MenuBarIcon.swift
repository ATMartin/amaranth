import AppKit
import SwiftUI
import Capture

/// The menu bar glyph (Inner Circle handoff): the `AmaranthMenuBar` speech ring and seed at 20 × 18 pt, as a template
/// image so macOS picks its colour for the menu bar it sits in. While a recording session is open a small shape sits
/// beside the mark (a record dot, pause bars, or an exclamation mark for the "Still recording?" alert, T68), so the state
/// never depends on colour; the accessibility description names it.
enum MenuBarIcon {
    enum State: CaseIterable {
        case idle, recording, paused, attention

        var accessibilityLabel: String {
            switch self {
            case .idle: "Amaranth, idle"
            case .recording: "Amaranth, recording"
            case .paused: "Amaranth, recording paused"
            case .attention: "Amaranth, still recording? No one has spoken for a while"
            }
        }

        /// The shape beside the mark, on whole points so it stays crisp at 1x; nil when idle.
        func badge(x: CGFloat) -> NSBezierPath? {
            switch self {
            case .idle: return nil
            case .recording: return NSBezierPath(ovalIn: NSRect(x: x, y: 5, width: 8, height: 8))
            case .paused:
                let p = NSBezierPath(rect: NSRect(x: x + 1, y: 5, width: 2, height: 8))
                p.append(NSBezierPath(rect: NSRect(x: x + 5, y: 5, width: 2, height: 8)))
                return p
            case .attention:
                let p = NSBezierPath(roundedRect: NSRect(x: x + 3, y: 8, width: 2, height: 7), xRadius: 1, yRadius: 1)
                p.append(NSBezierPath(ovalIn: NSRect(x: x + 3, y: 3, width: 2, height: 2)))
                return p
            }
        }

        @MainActor init(_ recorder: RecorderModel) {
            if recorder.quiet != nil { self = .attention }
            else if recorder.state == .paused || recorder.state == .interrupted { self = .paused }
            else if recorder.inSession { self = .recording }
            else { self = .idle }
        }
    }

    static let markSize = NSSize(width: 20, height: 18)
    static let badgeWidth: CGFloat = 8
    static let gap: CGFloat = 2

    @MainActor private static var cache: [State: NSImage] = [:]

    /// One template image per state, drawn at whatever scale the menu bar asks for.
    @MainActor static func image(_ state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        // The catalog image; a system waveform if it ever goes missing, so the menu bar is never blank.
        let mark = NSImage(named: "AmaranthMenuBar") ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        let hasBadge = state != .idle
        let width = markSize.width + (hasBadge ? gap + badgeWidth : 0)
        let image = NSImage(size: NSSize(width: width, height: markSize.height), flipped: false) { _ in
            mark?.draw(in: NSRect(origin: .zero, size: markSize))
            NSColor.black.setFill()
            state.badge(x: markSize.width + gap)?.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        cache[state] = image
        return image
    }
}

/// The MenuBarExtra label.
struct MenuBarLabel: View {
    let recorder: RecorderModel

    var body: some View {
        let state = MenuBarIcon.State(recorder)
        Image(nsImage: MenuBarIcon.image(state)).accessibilityLabel(state.accessibilityLabel)
    }
}
