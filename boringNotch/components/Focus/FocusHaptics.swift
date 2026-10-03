import AppKit
import Defaults

@MainActor
enum FocusHaptics {
    static func action() {
        guard Defaults[.enableHaptics] else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func detent(major: Bool) {
        guard Defaults[.enableHaptics] else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(major ? .levelChange : .alignment, performanceTime: .now)
    }
}
