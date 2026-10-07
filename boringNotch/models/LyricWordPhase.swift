import Foundation

/// A pure sample of the audio clock. No animation timer, delay or accumulated
/// state: seeking, pausing and changing playback speed produce the same frame.
struct LyricWordPhase {
    let isActive: Bool
    let progress: Double
    let duration: Double

    /// A soft light front and a narrow pearl crest. The endpoints match the
    /// stationary ink, so finishing a word cannot flash its last letter.
    func shimmerOpacity(at location: Double, feather: Double = 0.16) -> Double {
        guard isActive else { return progress >= 1 ? 0.94 : 0.60 }
        guard duration > 0.18 else { return 0.94 }
        let feather = min(0.28, max(0.08, feather))
        let edge = 0.03 + (1 + feather * 1.5) * progress
        let blend = min(1, max(0, (edge - location + feather) / (2 * feather)))
        let revealed = 0.60 + 0.34 * blend * blend * (3 - 2 * blend)
        let distance = abs(location - edge) / feather
        let crest = max(0, 1 - distance * distance)
        let settle = min(1, max(0, (1 - progress) / 0.12))
        return min(1, max(revealed, 0.60 + 0.40 * crest * settle))
    }

    /// Put a readable light edge on the first glyph at onset. The old 0...1.18
    /// edge spent the beginning of each word entering from outside its text.
    var revealEdge: Double { 0.18 + progress }

    // Completed ink stays bright. Dimming it again at every word boundary
    // creates a strobe during rap, even when the timestamps are correct.
    var inkOpacity: Double { isActive ? 0.85 : (progress >= 1 ? 1 : 0.65) }

    /// A line-only source cannot locate a word. This is a decorative sheen,
    /// independent of the guessed word durations, over an already-lit phrase.
    var sheenCenter: Double { -0.25 + 1.5 * progress }
    var phraseInkOpacity: Double { isActive ? 0.9 : inkOpacity }

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
