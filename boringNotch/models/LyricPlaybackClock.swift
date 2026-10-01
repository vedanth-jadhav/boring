import Foundation

/// Browser sampling and native receipt are different instants. Keeping the
/// original sample instant avoids adding transport latency to every lyric.
enum LyricPlaybackClock {
    static func sampleDate(milliseconds: Double?, receivedAt: Date) -> Date {
        guard let milliseconds, milliseconds.isFinite else { return receivedAt }
        let sample = Date(timeIntervalSince1970: milliseconds / 1000)
        let age = receivedAt.timeIntervalSince(sample)
        guard age >= -0.05, age < 2 else { return receivedAt }
        return sample
    }

    static func needsCorrection(position: Double, sampleDate: Date, anchorPosition: Double,
                                anchorDate: Date, rate: Double, playing: Bool) -> Bool {
        let estimate = anchorPosition + (playing ? sampleDate.timeIntervalSince(anchorDate) * rate : 0)
        return abs(position - estimate) > 0.012
    }
}
