import Foundation
import UserNotifications

protocol Notifying: Sendable {
    func post(title: String, body: String)
}

/// Records posts; for tests and for SessionManager's default.
final class RecordingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(title: String, body: String)] = []
    var posts: [(title: String, body: String)] { lock.withLock { _posts } }
    func post(title: String, body: String) { lock.withLock { _posts.append((title, body)) } }
}

/// UNUserNotificationCenter wrapper. `UNUserNotificationCenter.current()`
/// raises an Objective-C exception when the process is not an app bundle
/// (`swift run`, tests), which Swift cannot catch, so availability is checked
/// up front and everything degrades to a log line.
final class Notifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var authorizationRequested = false
    private var authorized = false
    let available: Bool

    init() {
        available = Self.runningInsideAppBundle()
        if !available {
            Log.info("notifications unavailable outside an app bundle; will log instead")
        }
    }

    static func runningInsideAppBundle() -> Bool {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier != nil else { return false }
        guard bundle.bundleURL.pathExtension == "app" else { return false }
        return bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL"
    }

    func requestAuthorizationIfNeeded() {
        guard available else { return }
        let first = lock.withLock { () -> Bool in
            if authorizationRequested { return false }
            authorizationRequested = true
            return true
        }
        guard first else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            }
            self?.lock.withLock { self?.authorized = granted }
            Log.info("notification authorization \(granted ? "granted" : "denied")")
        }
    }

    func post(title: String, body: String) {
        Log.info("notify: \(title) - \(body)")
        guard available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title.hasPrefix("Low Power Mode") ? title : title == "Caffeine session ended" ? "Caffeine complete" : "Caffeine"
        if title.hasPrefix("Low Power Mode") {
            content.body = title.hasSuffix("on") ? "Your Mac is using less power to protect its battery and temperature." : "Your Mac is back to its usual power setting."
        } else if ["Session ended", "Session restored", "Sleep restored"].contains(title) {
            content.body = "Your session has ended. Open Caffeine settings if an audio device still needs restoring."
        } else {
            content.body = "Caffeine needs your attention. Open the notch, choose Caffeine, then open Options."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("notification post failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Presents Caffeine's notifications while Caffeine is the active app.
/// With no delegate asking for it, macOS does not show a notification from
/// the frontmost app. Caffeine is frontmost right after a relaunch
/// confirmation, which activates it to bring the alert forward, so a
/// relaunch that failed within seconds would be reported to nobody. The
/// notification center holds its delegate weakly; `shared` keeps it.
final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundNotifications()
    /// While Caffeine is frontmost, a notification is shown as it would be
    /// otherwise.
    static let presentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    /// Becomes the notification center's delegate. Called before the app
    /// finishes launching, as the delegate has to be; does nothing outside
    /// an app bundle, where the notification center is not available.
    static func install() {
        guard Notifier.runningInsideAppBundle() else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.presentation
    }
}
