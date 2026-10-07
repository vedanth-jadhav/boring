import SwiftUI

struct CodexActivityAnchor: View {
    var width: CGFloat = CodexActivityMetrics.headerWidth
    var height: CGFloat = CodexActivityMetrics.height

    var body: some View {
        Color.clear.frame(width: width, height: height)
            .anchorPreference(key: CodexActivityAnchorKey.self, value: .bounds) { $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
