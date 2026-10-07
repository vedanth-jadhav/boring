import SwiftUI

/// A pure paint sample from the row's shared audio clock. No per-word timer,
/// animation state, delayed transition, geometry measurement or duplicate text.
struct HighlightedLyricWord: View {
    let text: String
    let pointSize: CGFloat
    let word: LyricLine.Word
    let elapsed: Double
    var hasExactTiming = true
    var reduceMotion = false

    var body: some View {
        let phase = LyricWordPhase(word: word, elapsed: elapsed)
        Text(text)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(LinearGradient(gradient: Self.ink(phase, exactTiming: hasExactTiming, reduceMotion: reduceMotion),
                                           startPoint: .leading, endPoint: .trailing))
            .transaction { $0.animation = nil }
    }

    static func ink(_ phase: LyricWordPhase, exactTiming: Bool, reduceMotion: Bool,
                    feather: Double = 0.16) -> Gradient {
        guard phase.isActive, !reduceMotion else {
            let opacity = phase.isActive ? 0.94 : phase.shimmerOpacity(at: 0)
            return Gradient(colors: [.white.opacity(opacity), .white.opacity(opacity)])
        }
        if exactTiming {
            if phase.duration <= 0.18 { return Gradient(colors: [.white.opacity(0.94), .white.opacity(0.94)]) }
            // Sample the smooth light profile; every stop remains ordered,
            // including as the crest leaves the final glyph.
            return Gradient(stops: (0...12).map { index in
                let location = Double(index) / 12
                return .init(color: .white.opacity(phase.shimmerOpacity(at: location, feather: feather)), location: location)
            })
        }
        // Every letter is readable at the real line onset. The sheen never
        // pretends that a character-count estimate is a sung-word timestamp.
        let center = phase.sheenCenter
        return Gradient(stops: [
            .init(color: .white.opacity(phase.phraseInkOpacity), location: 0),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: min(1, max(0, center - 0.25))),
            .init(color: .white.opacity(phase.visibleSheenOpacity), location: min(1, max(0, center))),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: min(1, max(0, center + 0.25))),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: 1)
        ])
    }
}
