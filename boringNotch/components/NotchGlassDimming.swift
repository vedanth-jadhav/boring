import SwiftUI

/// A smooth contrast veil anchored to the lower controls rather than stretched
/// over the whole panel when lyrics, notifications, or other content grow.
struct NotchGlassDimming: View {
    var expanded: Bool
    var increasedContrast: Bool

    // Keep the original smooth contrast profile, prepared once per variant.
    private static func gradient(floor: Double) -> Gradient {
        Gradient(stops: (0...16).map { step in
            let progress = Double(step) / 16
            let release = progress * progress * (3 - 2 * progress)
            return .init(color: .black.opacity(1 - release * (1 - floor)), location: progress)
        })
    }
    private static let normal = gradient(floor: 0.12)
    private static let highContrast = gradient(floor: 0.62)

    var body: some View {
        if expanded {
            GeometryReader { geometry in
                let depth = min(geometry.size.height * 0.58, 110)
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(gradient: increasedContrast ? Self.highContrast : Self.normal,
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: depth)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Color.black.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
