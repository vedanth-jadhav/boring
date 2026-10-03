import SwiftUI

/// One native optical surface. Smoke keeps the notch connection black while
/// the same glass reveals more backdrop below. Stops follow the Droppy frame.
struct LiquidGlassSurface<Content: View>: View {
    var shape: NotchShape
    var expanded: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var smoke: LinearGradient {
        let floor = contrast == .increased ? 0.62 : 0.10
        return LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.56),
            .init(color: .black.opacity(expanded ? 0.92 : 1), location: 0.63),
            .init(color: .black.opacity(expanded ? max(floor, 0.66) : 1), location: 0.72),
            .init(color: .black.opacity(expanded ? max(floor, 0.38) : 1), location: 0.82),
            .init(color: .black.opacity(expanded ? max(floor, 0.18) : 1), location: 0.92),
            .init(color: .black.opacity(expanded ? floor : 1), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        if #available(macOS 27.0, *), !reduceTransparency {
            // Keep content, sizing, matched geometry and material in the same
            // layout tree. A nested NSHostingController re-lays out its content
            // against intermediate AppKit bounds during expansion, which makes
            // leading-aligned elements slide sideways before settling.
            content
                .padding(.horizontal, shape.topCornerRadius)
                .background { smoke }
                .glassEffect(.clear, in: shape)
                .clipShape(shape)
        } else {
            // Solid accessibility/older-system fallback, with no legacy blur.
            content
                .padding(.horizontal, shape.topCornerRadius)
                .background {
                    shape.fill(LinearGradient(
                        colors: [.black, Color(white: expanded ? (contrast == .increased ? 0.035 : 0.075) : 0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
        }
    }
}
