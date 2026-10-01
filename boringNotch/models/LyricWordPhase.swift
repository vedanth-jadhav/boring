import Foundation

/// A pure sample of the audio clock. No animation timer, delay or accumulated
/// state: seeking, pausing and changing playback speed produce the same frame.
struct LyricWordPhase {
    let isActive: Bool
    let progress: Double
    let illumination: Double

    init(word: LyricLine.Word, elapsed: Double) {
        let duration = word.end - word.start
        guard elapsed.isFinite, duration.isFinite, duration > 0,
              elapsed >= word.start, elapsed < word.end else {
            isActive = false
            progress = elapsed >= word.end ? 1 : 0
            illumination = 0
            return
        }
        isActive = true
        progress = min(1, max(0, (elapsed - word.start) / duration))
        // Let the light breathe within the sung word. Fast syllables scale
        // down, while held vowels get a soft entrance and a longer release.
        let attack = min(0.12, duration * 0.28)
        let release = min(0.18, duration * 0.32)
        illumination = Self.smoothstep((elapsed - word.start) / attack)
            * Self.smoothstep((word.end - elapsed) / release)
    }

    /// Ease the reflection, keeping the raw audio phase available for scrolling.
    var reflectionProgress: Double { Self.smoothstep(progress) }

    static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
