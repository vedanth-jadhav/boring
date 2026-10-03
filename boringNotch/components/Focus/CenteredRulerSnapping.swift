import SwiftUI

struct CenteredRulerSnapping: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .center))
        } else {
            // Symmetric content margins place the leading target at the center
            // on macOS 14/15, before view-aligned behaviors gained an anchor.
            content.scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        }
    }
}
