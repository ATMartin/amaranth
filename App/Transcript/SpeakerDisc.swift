import SwiftUI
import Domain
import Presentation

/// Coloured initials disc for a speaker (T35); placeholder for avatars later. Colours come from a stable hash of the
/// speaker id into system colours that adapt to light and dark mode. No blue: that is the accent (your microphone in Bubbles).
struct SpeakerDisc: View {
    let assignment: SpeakerAssignment
    let name: String
    var size: CGFloat = 18
    @Environment(\.speakerColors) private var colors

    static let palette: [Color] = [.cyan, .purple, .pink, .orange, .green, .teal, .indigo, .brown]

    /// `indices` comes from `TranscriptRows.paletteIndices` for the meeting (distinct colours); unknown ids fall back
    /// to the plain hash.
    static func color(_ assignment: SpeakerAssignment, _ indices: [SpeakerID: Int] = [:]) -> Color {
        if case .speaker(let id) = assignment { palette[(indices[id] ?? TranscriptRows.paletteIndex(id)) % palette.count] } else { .gray }
    }

    var body: some View {
        ZStack {
            Circle().fill(Self.color(assignment, colors))
            switch assignment {
            case .speaker: Text(TranscriptRows.initials(name)).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            case .multiple: Image(systemName: "person.2.fill").font(.system(size: size * 0.4)).foregroundStyle(.white)
            case .unknown: Text("?").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
