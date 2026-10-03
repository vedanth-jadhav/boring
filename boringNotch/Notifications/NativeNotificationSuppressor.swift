import Foundation

@MainActor protocol NativeBannerSuppressing {
    func suppress(_ notification: MirroredNotification) async -> Bool
}
/// Dismissal is optional and independent of capture, presentation and replies.
@MainActor struct NativeNotificationSuppressor: NativeBannerSuppressing {
    func suppress(_ notification: MirroredNotification) async -> Bool {
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else { return false }
        return await XPCHelperClient.shared.suppressNativeNotification(notification)
    }
}
