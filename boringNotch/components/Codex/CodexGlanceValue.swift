import SwiftUI

/// Roll the whole reading when a percentage changes into a reset time.
struct CodexGlanceValue: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text(value)
                .id(value)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: 12).combined(with: .opacity),
                    removal: .offset(y: -12).combined(with: .opacity)
                ))
        }
        .frame(height: 14)
        .clipped()
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: value)
    }
}
