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
            .foregroundStyle(ink(phase))
            .transaction { $0.animation = nil }
    }

    private func ink(_ phase: LyricWordPhase) -> LinearGradient {
        guard phase.isActive, !reduceMotion else {
            let opacity = phase.isActive ? 1 : phase.inkOpacity
            return LinearGradient(colors: [.white.opacity(opacity), .white.opacity(opacity)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        if hasExactTiming {
            return LinearGradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: max(0, phase.revealEdge - 0.18)),
                .init(color: .white.opacity(phase.inkOpacity), location: min(1, phase.revealEdge)),
                .init(color: .white.opacity(phase.inkOpacity), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
        // Every letter is readable at the real line onset. The sheen never
        // pretends that a character-count estimate is a sung-word timestamp.
        let center = phase.sheenCenter
        return LinearGradient(stops: [
            .init(color: .white.opacity(phase.phraseInkOpacity), location: 0),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: min(1, max(0, center - 0.25))),
            .init(color: .white.opacity(phase.visibleSheenOpacity), location: min(1, max(0, center))),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: min(1, max(0, center + 0.25))),
            .init(color: .white.opacity(phase.phraseInkOpacity), location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }
}
