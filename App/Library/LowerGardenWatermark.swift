import SwiftUI

/// Lower Garden (docs/lower-garden-handoff, approved 2026-10-28): a single-tone botanical watermark behind the meeting
/// library. Attach it as the background of the whole sidebar body, above its Canvas fill; it takes the body's size and
/// never changes it. The art keeps its fixed 390 × 585 pt size, anchored bottom-trailing and pushed 105 pt right and 24 pt
/// down, so a narrow or short sidebar crops it. Fades in from 20% of the sidebar's height, out by 91%, then 12% opacity
/// once. Decorative: no hit testing, not in the accessibility tree, and hidden with Increase Contrast or Reduce
/// Transparency (live, through the environment).
struct LowerGardenWatermark: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let artSize = CGSize(width: 390, height: 585)
    static let offset = CGSize(width: 105, height: 24)
    static let opacity = 0.12
    static let fade: [Gradient.Stop] = [
        .init(color: .clear, location: 0), .init(color: .clear, location: 0.2), .init(color: .white, location: 0.58),
        .init(color: .white, location: 0.76), .init(color: .clear, location: 0.91), .init(color: .clear, location: 1),
    ]

    static func shown(contrast: ColorSchemeContrast, reduceTransparency: Bool) -> Bool {
        contrast != .increased && !reduceTransparency
    }

    var body: some View {
        if Self.shown(contrast: contrast, reduceTransparency: reduceTransparency) {
            GeometryReader { geometry in
                // An aligned frame, not the handoff helper's ZStack: the art is wider than the sidebar, so a ZStack grows to
                // 390 pt and is centred, putting the garden ~85 pt right of the approved spot at 220 pt.
                Image("AmaranthLowerGardenMask")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(Color.watermarkTint)
                    .frame(width: Self.artSize.width, height: Self.artSize.height)
                    .offset(Self.offset)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                    .clipped()
                .mask { LinearGradient(stops: Self.fade, startPoint: .top, endPoint: .bottom) }
                .opacity(Self.opacity)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
