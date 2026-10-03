import SwiftUI

/// Destinations supply geometry only. The actual activity has one stable identity
/// in ContentView's overlay, outside the notch's clipping and content transitions.
struct FocusActivityAnchor: View {
    var width: CGFloat = 86
    var height: CGFloat = 28

    var body: some View {
        Color.clear.frame(width: width, height: height)
            .anchorPreference(key: FocusActivityAnchorKey.self, value: .bounds) { $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct FocusActivityAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
