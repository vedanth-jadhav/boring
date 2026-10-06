import Foundation

/// Browser sampling and native receipt are different instants. Keeping the
/// original sample instant avoids adding transport latency to every lyric.
enum LyricPlaybackClock {
    static func sampleDate(milliseconds: Double?, receivedAt: Date) -> Date {
        guard let milliseconds, milliseconds.isFinite else { return receivedAt }
        let sample = Date(timeIntervalSince1970: milliseconds / 1000)
        let age = receivedAt.timeIntervalSince(sample)
        // Native reconnect can replay a valid heartbeat older than two seconds.
        // Replacing its sample date with receipt time loses all intervening
        // playback and leaves the lyrics behind until the next heartbeat.
        guard age >= -0.05, age < 60 else { return receivedAt }
        return sample
    }

    static func needsCorrection(position: Double, sampleDate: Date, anchorPosition: Double,
                                anchorDate: Date, rate: Double, playing: Bool) -> Bool {
        let estimate = anchorPosition + (playing ? sampleDate.timeIntervalSince(anchorDate) * rate : 0)
        // Browser samples are precise, unlike integer-second media metadata.
        // Ignore only sub-frame jitter, not an audible 150 ms disagreement.
        return abs(position - estimate) > 0.015
    }

    static func position(anchorPosition: Double, anchorDate: Date, at date: Date,
                         rate: Double, playing: Bool, duration: Double) -> Double {
        let delta = playing ? date.timeIntervalSince(anchorDate) * max(0, rate) : 0
        return min(max(0, anchorPosition + delta), duration)
    }
}
