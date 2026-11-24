import SwiftUI
import Presentation

/// Settings → Appearance → Transcript style: one card per style with a skeleton mock-up of a few lines, so the choice
/// is visible before making it. The choice is stored under `TranscriptStyle.key`.
struct TranscriptStylePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: AppStyle.double) {
            ForEach(TranscriptStyle.allCases) { style in
                let selected = TranscriptStyle(stored: selection) == style
                Button { selection = style.rawValue } label: {
                    VStack(spacing: AppStyle.grid) {
                        TranscriptStyleSkeleton(style: style)
                            .padding(10)
                            .frame(width: 180, height: 96)
                            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected ? Color.brandAccent : Color.controlBorder.opacity(0.6), lineWidth: selected ? 2.5 : 1)
                            }
                        Text(style.title).appFont(.callout, weight: selected ? .semibold : .regular)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A few grey bars standing in for transcript lines; speaker colours from the transcript palette.
struct TranscriptStyleSkeleton: View {
    let style: TranscriptStyle
    private let bar = Color.brandSecondary.opacity(0.35)
    private let them = SpeakerDisc.palette[1], other = SpeakerDisc.palette[3]

    var body: some View {
        switch style {
        case .columns:
            // The aligned transcript: a time column, then the name above the words, one reading edge.
            VStack(alignment: .leading, spacing: 4) {
                run(disc: them, lines: [0.95, 0.6])
                run(disc: other, lines: [0.8])
                run(disc: SpeakerDisc.palette[0], lines: [0.9])
            }
        case .bubbles:
            VStack(spacing: 5) {
                bubble(them, width: 0.7, mine: false)
                bubble(Color.brandAccent, width: 0.55, mine: true)
                bubble(other, width: 0.75, mine: false)
                bubble(Color.brandAccent, width: 0.45, mine: true)
            }
        }
    }

    func run(disc: Color, lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(bar.opacity(0.6)).frame(width: 18, height: 5).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Circle().fill(disc).frame(width: 8, height: 8)
                    Capsule().fill(bar).frame(width: 22, height: 5)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                    GeometryReader { g in Capsule().fill(bar).frame(width: g.size.width * w, height: 5) }.frame(height: 5)
                }
            }
        }
    }

    func bubble(_ color: Color, width: CGFloat, mine: Bool) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(mine ? 0.85 : 0.25))
                .frame(width: g.size.width * width, height: 12)
                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
        .frame(height: 12)
    }
}
