import Defaults
import SwiftUI

struct ShelfGlass: ViewModifier {
    var active = false
    var tint: Color = .white
    var radius: CGFloat = 16
    @Default(.reduceGlass) private var reduceGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 27.0, *), !reduceTransparency, !reduceGlass {
            content.glassEffect(.regular.tint(active ? tint.opacity(0.28) : .clear).interactive(), in: .rect(cornerRadius: radius))
        } else {
            content.background {
                RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius).fill(active ? tint.opacity(0.28) : .clear)
                    }
            }
        }
    }
}
