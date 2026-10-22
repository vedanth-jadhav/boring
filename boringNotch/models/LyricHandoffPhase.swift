import Foundation

/// A short optical handoff, measured on the same clock as the new phrase.
/// Incoming text is readable from its first frame; seeking never queues an animation.
struct LyricHandoffPhase {
    let progress: Double

    init(start: Double, elapsed: Double, duration: Double = 0.16, reduceMotion: Bool = false) {
        guard !reduceMotion, start.isFinite, elapsed.isFinite, duration.isFinite, duration > 0,
              elapsed >= start, elapsed < start + duration else {
            progress = 1
            return
        }
        progress = min(1, max(0, (elapsed - start) / duration))
    }

    private var remaining: Double { pow(1 - progress, 3) }
    var incomingOpacity: Double { 1 - 0.16 * remaining }
    var outgoingOpacity: Double { 0.16 * remaining }
}
