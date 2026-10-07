import Defaults
import SwiftUI

struct CodexActivitySurface: ViewModifier {
    @Default(.reduceGlass) private var reduceGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var expanded: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceGlass, !reduceTransparency, contrast != .increased {
            content.glassEffect(expanded ? .identity : .regular.interactive(), in: Capsule())
        } else {
            content.background(Color(white: 0.075).opacity(expanded ? 0 : 1), in: Capsule())
        }
    }
}
