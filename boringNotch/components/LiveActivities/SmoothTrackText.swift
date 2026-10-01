import SwiftUI

/// A stable text slot lets outgoing and incoming metadata share a crossfade.
struct SmoothTrackText: View {
    let text: String
    let font: Font
    let color: Color
    let width: CGFloat
    var height: CGFloat = NSFont.preferredFont(forTextStyle: .headline).pointSize * 1.3
    var delayDuration: Double = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            MarqueeText(text, font: font, color: color, delayDuration: delayDuration, frameWidth: width)
                .id(text)
                .transition(.opacity)
        }
        .frame(width: max(0, width), height: height, alignment: .leading)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: reduceMotion ? 0.15 : 0.5), value: text)
    }
}
