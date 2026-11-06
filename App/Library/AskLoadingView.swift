import SwiftUI
import Domain
import Presentation

/// The Ask loading graphic (spec 0010, T115): a small ring of seeds in the Inner Circle / Forest identity — rose and
/// sage seeds orbiting a cream center with a gentle pulse — and short stage copy. It appears as soon as a question is
/// submitted and stays through model loading, planning, retrieval and pre-answer generation; the parent swaps it for the
/// streamed text or a terminal state, so it never animates forever. Reduce Motion: the same ring, still. VoiceOver: one
/// progress element with the stage, and Cancel stays reachable.
struct AskLoadingView: View {
    let stage: AskStage
    let waitingReason: String?
    let started: Date?
    var cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// ui-render: draw the Reduce Motion variant without changing the system setting.
    @Environment(\.stillLoader) private var stillLoader
    var reduceMotion: Bool { systemReduceMotion || stillLoader }

    var body: some View {
        HStack(alignment: .center, spacing: AppStyle.grid + 4) {
            Group {
                if reduceMotion {
                    SeedRing(phase: 0, pulse: 0.5)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        SeedRing(phase: t.truncatingRemainder(dividingBy: 6) / 6, pulse: (sin(t * 1.6) + 1) / 2)
                    }
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(waitingReason ?? ContextualAsk.stageText(stage)).appFont(.callout).foregroundStyle(Color.brandText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On this Mac, up to 15 s").appFont(.caption2).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel).buttonStyle(.brandLink).appFont(.caption)
                .keyboardShortcut(.cancelAction)
                .help("Stop answering (Esc)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Answering: \(waitingReason ?? ContextualAsk.stageText(stage))")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: "Cancel", cancel)
    }
}

/// Eight seeds on a ring around a cream heart: alternating rose and sage, one brighter seed leading the orbit.
struct SeedRing: View {
    /// 0…1 around the ring.
    let phase: Double
    /// 0…1 breathing of the center.
    let pulse: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 3
            let heart = 4 + 1.5 * pulse
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - heart, y: c.y - heart, width: heart * 2, height: heart * 2)), with: .color(Color.surface))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - heart, y: c.y - heart, width: heart * 2, height: heart * 2)), with: .color(Color.sage.opacity(0.6)), lineWidth: 1)
            let n = 8
            for i in 0..<n {
                let a = (Double(i) / Double(n) + phase) * 2 * .pi
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                let lead = i == 0
                let s: CGFloat = lead ? 3.4 : 2.4
                let color = i % 2 == 0 ? Color.brandAccent : Color.sage
                // A seed: a small ellipse turned along the ring.
                var seed = Path(ellipseIn: CGRect(x: -s, y: -s * 0.65, width: s * 2, height: s * 1.3))
                seed = seed.applying(CGAffineTransform(rotationAngle: a + .pi / 2)).applying(CGAffineTransform(translationX: p.x, y: p.y))
                ctx.fill(seed, with: .color(color.opacity(lead ? 1 : 0.55 + 0.25 * Double(i % 3) / 2)))
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var stillLoader = false
}
