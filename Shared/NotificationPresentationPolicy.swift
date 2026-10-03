import Foundation

/// Explicit priority: onboarding / drag / manual workspace / HUD > messages
/// > music > idle. Deferred messages stay in the queue and do not steal tabs.
enum NotificationPresentationPolicy {
    enum Mode: Equatable { case hidden, deferred, stack }
    static func mode(hasNotifications: Bool, unavailable: Bool, hidden: Bool,
                     onboarding: Bool, dragging: Bool, workspaceOpen: Bool, systemHUD: Bool) -> Mode {
        guard hasNotifications, !unavailable, !hidden else { return .hidden }
        if onboarding || dragging || workspaceOpen || systemHUD { return .deferred }
        return .stack
    }
}
