import SwiftUI

struct ShimmeringLyricWord: View {
    let text: String
    let pointSize: CGFloat
    let phase: LyricWordPhase
    let shimmer: Bool

    var body: some View {
        let light = shimmer ? phase.illumination : 0
        Text(text)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .overlay {
                GeometryReader { geometry in
                    let band = max(geometry.size.height * 2.4, geometry.size.width * 0.9)
                    ZStack(alignment: .leading) {
                        // A quiet wash carries the vocal through the sweep;
                        // one broad crest avoids the old double-flash effect.
                        Color.white.opacity(0.28)
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.12), location: 0.16),
                            .init(color: .white.opacity(0.55), location: 0.34),
                            .init(color: .white, location: 0.5),
                            .init(color: .white.opacity(0.55), location: 0.66),
                            .init(color: .white.opacity(0.12), location: 0.84),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band, height: geometry.size.height * 2)
                        .rotationEffect(.degrees(-12))
                        .offset(x: -band + (geometry.size.width + band) * phase.reflectionProgress,
                                y: -geometry.size.height * 0.5)
                    }
                }
                .mask(Text(text).font(.system(size: pointSize, weight: .medium)))
                .opacity(shimmer ? light : 0)
                .allowsHitTesting(false)
            }
            // Timing is sampled directly. Implicit animations here introduce
            // lag and continue incorrectly across pause/seek boundaries.
            .transaction { $0.animation = nil }
    }
}
