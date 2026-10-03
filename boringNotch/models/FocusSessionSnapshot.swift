import Foundation

/// Only transitions are persisted. Seconds are samples of the absolute deadline.
struct FocusSessionSnapshot: Codable, Equatable {
    var mode: FocusSessionMode = .timer
    var state: FocusSessionState = .idle
    var duration: TimeInterval = 25 * 60
    var deadline: Date?
    var pausedRemaining: TimeInterval = 0

    func remaining(at date: Date) -> TimeInterval {
        switch state {
        case .idle: return 0
        case .running: return max(0, deadline?.timeIntervalSince(date) ?? 0)
        case .paused: return max(0, pausedRemaining)
        }
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: date) / duration))
    }

    var isValid: Bool {
        guard duration.isFinite, (60...7200).contains(duration), pausedRemaining.isFinite,
              (0...duration).contains(pausedRemaining) else { return false }
        switch state {
        case .idle: return deadline == nil
        case .running: return deadline != nil && deadline!.timeIntervalSince1970.isFinite
        case .paused: return deadline == nil && pausedRemaining > 0
        }
    }

    static func timeText(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, remaining)))
        // Keep minutes visible for 60+ minute sessions, without changing digit widths.
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
