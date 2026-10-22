import Foundation

/// A pure sample of the audio clock. No animation timer, delay or accumulated
/// state: seeking, pausing and changing playback speed produce the same frame.
struct LyricWordPhase {
    let isActive: Bool
    let progress: Double
    let duration: Double

    private func smooth(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    /// Light enters and settles with zero velocity. At either timestamp the
    /// paint exactly matches the stationary glyph, even for very short words.
    func shimmerOpacity(at location: Double, feather: Double = 0.16) -> Double {
        guard isActive else { return progress >= 1 ? 0.94 : 0.60 }
        let attack = smooth(progress / min(0.5, 0.028 / duration))
        guard duration > 0.18 else { return 0.60 + 0.34 * attack }
        let feather = min(0.28, max(0.08, feather))
        let edge = 0.03 + (1 + feather * 1.5) * progress
        let revealed = 0.60 + 0.34 * smooth((edge - location + feather) / (2 * feather)) * attack
        let distance = abs(location - edge) / feather
        let crestBase = max(0, 1 - distance * distance)
        let crest = crestBase * crestBase
        let settle = smooth((1 - progress) / 0.18)
        let ink = revealed + (1 - revealed) * 0.42 * crest * attack * settle
        return min(1, max(0.60, ink))
    }

    /// A line-only source cannot locate a word. This is a decorative sheen,
    /// independent of the guessed word durations, over an already-lit phrase.
    var sheenCenter: Double { -0.25 + 1.5 * progress }
    var phraseInkOpacity: Double { isActive || progress >= 1 ? 0.9 : 0.65 }

    // As the crest enters/leaves the glyph bounds, its visible intensity
    // approaches the base ink continuously rather than sticking to an edge.
    var visibleSheenOpacity: Double {
        let clippedCenter = min(1, max(0, sheenCenter))
        return 0.9 + 0.1 * max(0, 1 - abs(sheenCenter - clippedCenter) / 0.25)
    }

    init(word: LyricLine.Word, elapsed: Double) {
        duration = word.end - word.start
        guard elapsed.isFinite, word.start.isFinite, word.end.isFinite,
              duration.isFinite, duration > 0 else {
            isActive = false
            progress = 0
            return
        }
        guard elapsed >= word.start, elapsed < word.end else {
            isActive = false
            progress = elapsed >= word.end ? 1 : 0
            return
        }
        isActive = true
        progress = min(1, max(0, (elapsed - word.start) / duration))
    }
}
