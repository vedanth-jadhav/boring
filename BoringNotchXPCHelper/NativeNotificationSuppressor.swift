import AppKit
import ApplicationServices

/// A separate, dismiss-only AX client. It has no reply field, text input, open
/// action or source publication. A missing/ambiguous banner is left untouched.
final class NativeNotificationSuppressor {
    private let worker = DispatchQueue(label: "boring.notifications.suppression", qos: .utility)
    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func strings(in root: AXUIElement) -> [String] {
        descendants(root).compactMap { element in
            guard attribute(element, kAXRoleAttribute) as? String == "AXStaticText" else { return nil }
            return NotificationParser.clean(attribute(element, kAXValueAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String)
        }
    }
    private func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root], result: [AXUIElement] = [], seen = Set<CFHashCode>()
        while let element = queue.popLast(), seen.count < 256 {
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? attribute(element, "AXContents") as? [AXUIElement] ?? [])
        }
        return result
    }
    private func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
    func suppress(_ notification: MirroredNotification, completion: @escaping (Bool) -> Void) {
        worker.async {
            guard AXIsProcessTrusted() else { completion(false); return }
            let applications = ["com.apple.notificationcenterui", "com.apple.UserNotificationCenter"].flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0)
            }
            let windows = applications.flatMap { app -> [AXUIElement] in
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.15)
                return self.attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            }
            var matches: [AXUIElement] = []
            for window in windows.prefix(32) {
                let elements = self.descendants(window)
                guard !elements.contains(where: {
                    NotificationPanelDetection.isPanel(subrole: self.attribute($0, kAXSubroleAttribute) as? String,
                        identifier: self.attribute($0, kAXIdentifierAttribute) as? String)
                    || self.attribute($0, kAXIdentifierAttribute) as? String == NotificationPanelDetection.panelListIdentifier
                }) else { continue }
                let recognized = elements.filter { NotificationPanelDetection.isBanner(subrole: self.attribute($0, kAXSubroleAttribute) as? String) }
                // Some macOS releases expose the banner window as AXUnknown.
                // Still require exact semantic identity and a real dismiss action.
                for banner in recognized.isEmpty ? [window] : recognized {
                    let subrole = self.attribute(banner, kAXSubroleAttribute) as? String
                    if subrole == "AXNotificationCenterBannerWindow" || subrole == "AXNotificationCenterAlertStack" {
                        let nested = self.descendants(banner).dropFirst().contains { child in
                            let role = self.attribute(child, kAXSubroleAttribute) as? String
                            return NotificationPanelDetection.isBanner(subrole: role) && role != "AXNotificationCenterBannerWindow" && role != "AXNotificationCenterAlertStack"
                        }
                        if nested { continue }
                    }
                    let text = self.strings(in: banner)
                    let description = (self.attribute(banner, "AXAttributedDescription") as? NSAttributedString)?.string ?? self.attribute(banner, "AXAttributedDescription") as? String ?? self.attribute(banner, kAXDescriptionAttribute) as? String
                    let bundle = self.attribute(banner, "AXBundleIdentifier") as? String
                    guard NativeBannerMatch.matches(notification, texts: text, appDescription: description, bundleID: bundle) else { continue }
                    if !matches.contains(where: { CFEqual($0, banner) }) { matches.append(banner) }
                }
            }
            guard matches.count == 1, let banner = matches.first else { completion(false); return }
            if self.actions(banner).contains(kAXCancelAction) {
                completion(AXUIElementPerformAction(banner, kAXCancelAction as CFString) == .success); return
            }
            let dismissActions = self.actions(banner).filter(NativeBannerMatch.isDismissAction)
            if dismissActions.count == 1, let action = dismissActions.first {
                completion(AXUIElementPerformAction(banner, action as CFString) == .success); return
            }
            let buttons = self.descendants(banner).filter { element in
                guard self.attribute(element, kAXRoleAttribute) as? String == "AXButton",
                      self.attribute(element, kAXEnabledAttribute) as? Bool != false,
                      self.actions(element).contains(kAXPressAction) else { return false }
                let label = self.attribute(element, kAXTitleAttribute) as? String ?? self.attribute(element, kAXDescriptionAttribute) as? String ?? ""
                return NativeBannerMatch.isDismissLabel(label)
            }
            guard buttons.count == 1, let button = buttons.first else { completion(false); return }
            completion(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
        }
    }
}
