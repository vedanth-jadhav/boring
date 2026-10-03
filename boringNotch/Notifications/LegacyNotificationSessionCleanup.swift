import Foundation
import WebKit

/// One-time removal of this feature's former web profiles, never Safari or any
/// other app's data. There are no webviews or browser providers after migration.
@MainActor enum LegacyNotificationSessionCleanup {
    static func run() async {
        let defaults = UserDefaults.standard
        let key = "nativeNotificationSessionCleanup.v1"
        guard !defaults.bool(forKey: key) else { return }
        for service in ["whatsapp", "telegram", "imessage"] {
            defaults.removeObject(forKey: "notificationReplySession.\(service)")
        }
        for identifier in ["038D8E66-391C-4F87-B1B9-C0EAF3260041", "93F0F6D3-A1D7-4C5F-8886-3393B4213229"] {
            guard let id = UUID(uuidString: identifier) else { continue }
            let store = WKWebsiteDataStore(forIdentifier: id)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        defaults.set(true, forKey: key)
    }
}
