import SwiftUI

/// Decorative background for the complete sidebar body, below its content.
/// The parent supplies the sidebar's size; attach with `.background { ... }`.
@available(macOS 13.0, *)
public struct LowerGardenWatermark: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let bundle: Bundle
    private let isEnabled: Bool

    public init(bundle: Bundle = .main, isEnabled: Bool = true) {
        self.bundle = bundle
        self.isEnabled = isEnabled
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Image("AmaranthLowerGardenMask", bundle: bundle)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(Color("AmaranthWatermarkTint", bundle: bundle))
                    .frame(width: 390, height: 585)
                    .offset(x: 105, y: 24)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.20),
                        .init(color: .white, location: 0.58),
                        .init(color: .white, location: 0.76),
                        .init(color: .clear, location: 0.91),
                        .init(color: .clear, location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .opacity(isEnabled && contrast != .increased && !reduceTransparency ? 0.12 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
