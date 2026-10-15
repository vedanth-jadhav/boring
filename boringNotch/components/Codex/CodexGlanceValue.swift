import SwiftUI

/// Keep digits alive during countdowns; transition the reading only when its unit changes.
struct CodexGlanceValue: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text(value)
                .contentTransition(.numericText(countsDown: !value.hasSuffix(" used")))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: value)
                .id(value.contains("%"))
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: 6).combined(with: .opacity),
                    removal: .offset(y: -6).combined(with: .opacity)
                ))
        }
        .frame(height: 14)
        .clipped()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: value.contains("%"))
    }
}
