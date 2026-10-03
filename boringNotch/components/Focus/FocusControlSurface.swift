import SwiftUI

/// Use the system's refractive Liquid Glass for controls, respecting transparency
/// preferences. The activity itself remains black like the physical notch.
struct FocusControlSurface: ViewModifier {
    var accent: Bool = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.tint(accent ? .orange.opacity(0.28) : .clear).interactive(), in: Capsule())
        } else {
            content.background(accent ? Color.orange.opacity(0.2) : Color.white.opacity(0.1), in: Capsule())
        }
    }
}
