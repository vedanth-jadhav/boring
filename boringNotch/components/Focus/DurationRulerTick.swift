import SwiftUI

struct DurationRulerTick: View {
    let minute: Int
    let spacing: CGFloat

    private var major: Bool { minute.isMultiple(of: 5) }
    private var height: CGFloat {
        if minute.isMultiple(of: 15) { return 25 }
        if minute.isMultiple(of: 10) { return 22 }
        return major ? 18 : 11
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(major || minute == 1 ? "\(minute)" : "")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .fixedSize()
                .foregroundStyle(.orange.opacity(0.85))
                .frame(height: 12)
            Capsule().fill(Color.orange.opacity(major ? 0.9 : 0.45))
                .frame(width: major ? 2 : 1, height: height)
                .frame(height: 25, alignment: .bottom)
        }
        .frame(width: spacing, height: 52, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
