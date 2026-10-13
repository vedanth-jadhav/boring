import Foundation

/// Pure session arithmetic. No clocks, no side effects.
enum SessionMath {
    /// Shortest session we accept.
    static let minimumDuration: TimeInterval = 60

    /// Clamp a requested duration into `[minimumDuration, maxDuration]`.
    static func clamp(_ duration: TimeInterval, maxDuration: TimeInterval) -> TimeInterval {
        let upper = max(maxDuration, minimumDuration)
        return min(max(duration, minimumDuration), upper)
    }

    /// End time for a session starting at `start`.
    static func endsAt(start: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Date {
        start.addingTimeInterval(clamp(duration, maxDuration: maxDuration))
    }

    /// Fresh session starting now.
    static func newSession(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> Session {
        Session(startedAt: now, endsAt: endsAt(start: now, duration: duration, maxDuration: maxDuration))
    }

    /// Push `endsAt` out by `extra` seconds, never past `now + maxDuration`.
    /// Extending an already-expired session restarts the countdown from `now`.
    static func extended(_ session: Session, by extra: TimeInterval, now: Date, maxDuration: TimeInterval) -> Session {
        let base = max(session.endsAt, now)
        let ceiling = now.addingTimeInterval(max(maxDuration, minimumDuration))
        let proposed = base.addingTimeInterval(max(extra, 0))
        let newEnd = min(proposed, ceiling)
        var s = session
        s.extensions.append(newEnd.timeIntervalSince(session.endsAt))
        s.endsAt = newEnd
        return s
    }

    /// Seconds from `now` to `endsAt`, floored at zero.
    static func remaining(until endsAt: Date, at now: Date) -> TimeInterval {
        max(endsAt.timeIntervalSince(now), 0)
    }

    static func isExpired(endsAt: Date, at now: Date) -> Bool {
        endsAt.timeIntervalSince(now) <= 0
    }

    /// Minute-granularity remaining time: "3d 2h", "2h 14m", "14m", "<1m".
    /// Zero secondary units are dropped ("2h", "3d"). Seconds are floored.
    static func formatRemaining(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(max(interval, 0) / 60)
        if totalMinutes < 1 { return "<1m" }
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// Live menu bar countdown, ticking every second in a fixed `shape`.
    ///
    /// Partial seconds round *up*, so a fresh 30-minute session opens on
    /// `30:00` and the text only reads all-zeros once the deadline is reached.
    /// Negative input is floored at zero. Minutes and seconds are always two
    /// digits; hours and days are never padded.
    static func formatCountdown(remaining: TimeInterval, shape: CountdownShape) -> String {
        let total = Int(max(remaining, 0).rounded(.up))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        func clock(hours: Int) -> String {
            String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        switch shape {
        case .days:
            let days = total / 86400
            guard days > 0 else { return clock(hours: total / 3600) }
            return "\(days)d " + clock(hours: (total % 86400) / 3600)
        case .hours:
            return clock(hours: total / 3600)
        case .minutes:
            return String(format: "%02d:%02d", total / 60, seconds)
        }
    }

    /// Next wall-clock minute boundary at or after `now` (for the redraw timer).
    static func nextMinuteBoundary(after now: Date) -> Date {
        let t = now.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (floor(t / 60) + 1) * 60)
    }

    /// Next whole wall-clock second after `now` (for the 1 Hz countdown timer).
    static func nextSecondBoundary(after now: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: floor(now.timeIntervalSinceReferenceDate) + 1)
    }
}

/// Shape of the live menu bar countdown.
///
/// Chosen once from the session's initial duration and held for the whole
/// session so the status item keeps a stable width instead of jittering as
/// units drop off. The only mid-session change is `days` losing its day
/// component once fewer than 24 hours remain.
enum CountdownShape: Equatable, Sendable {
    /// `Nd H:MM:SS` while a day or more remains, then `H:MM:SS`.
    case days
    /// `H:MM:SS` for the whole session, even under an hour (`0:04:07`).
    case hours
    /// `MM:SS` for the whole session (`04:07`, `00:09`).
    case minutes

    init(initialDuration: TimeInterval) {
        if initialDuration >= 86400 {
            self = .days
        } else if initialDuration >= 3600 {
            self = .hours
        } else {
            self = .minutes
        }
    }
}
