import AppKit
import ApplicationServices

/// Bounded, event-scoped early capture. No tree polling or notification input.
final class AXNotificationSource {
    private struct Occurrence { let key: String; let date: Date }
    private var occurrences: [CFHashCode: Occurrence] = [:]
    private let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute,
                        "AXContents", kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                        "AXAttributedDescription", "AXBundleIdentifier", kAXPositionAttribute]
    func begin(_ root: AXUIElement) {
        let hash = CFHash(root)
        if let prior = occurrences[hash], Date().timeIntervalSince(prior.date) > 0.12 { occurrences.removeValue(forKey: hash) }
    }
    func read(_ root: AXUIElement) -> MirroredNotification? {
        guard AXIsProcessTrusted() else { occurrences.removeAll(); return nil }
        AXUIElementSetMessagingTimeout(root, 0.04)
        let started = DispatchTime.now().uptimeNanoseconds
        var pending = [root], nodes: [[String: Any]] = [], seen = Set<CFHashCode>()
        while let element = pending.popLast(), nodes.count < 64 {
            // One IPC per node and a short work budget. An incomplete/unresponsive
            // tree falls back to the store without blocking capture for seconds.
            guard DispatchTime.now().uptimeNanoseconds - started < 25_000_000 else { return nil }
            guard seen.insert(CFHash(element)).inserted else { continue }
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values) == .success,
                  let values = values as? [Any], values.count == keys.count else { return nil }
            let node = Dictionary(uniqueKeysWithValues: zip(keys, values))
            if NotificationPanelDetection.isPanel(subrole: node[kAXSubroleAttribute] as? String, identifier: node[kAXIdentifierAttribute] as? String)
                || node[kAXIdentifierAttribute] as? String == NotificationPanelDetection.panelListIdentifier { return nil }
            nodes.append(node)
            pending += node[kAXChildrenAttribute] as? [AXUIElement] ?? node["AXContents"] as? [AXUIElement] ?? []
        }
        guard pending.isEmpty else { return nil }
        let leaves = nodes.filter {
            guard let subrole = $0[kAXSubroleAttribute] as? String else { return false }
            return NotificationPanelDetection.isBanner(subrole: subrole) && !["AXNotificationCenterBannerWindow", "AXNotificationCenterAlertStack"].contains(subrole)
        }
        guard leaves.count <= 1 else { return nil }
        let descriptions = nodes.prefix(12).compactMap { node -> String? in
            (node["AXAttributedDescription"] as? NSAttributedString)?.string
                ?? node["AXAttributedDescription"] as? String ?? node[kAXDescriptionAttribute] as? String
        }
        let bundle = nodes.prefix(12).compactMap { $0["AXBundleIdentifier"] as? String }.first
        let texts = nodes.filter { $0[kAXRoleAttribute] as? String == "AXStaticText" }.compactMap { node -> NotificationBannerText? in
            guard let text = NotificationParser.clean(node[kAXValueAttribute] as? String ?? node[kAXTitleAttribute] as? String) else { return nil }
            var position = CGPoint.zero
            if let value = node[kAXPositionAttribute], CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
            }
            return .init(value: text, identifier: node[kAXIdentifierAttribute] as? String ?? "", x: position.x, y: position.y)
        }
        let isWhatsApp = bundle?.lowercased().contains("whatsapp") == true
            || descriptions.contains { NotificationParser.clean($0.components(separatedBy: ",").first)?.caseInsensitiveCompare("WhatsApp") == .orderedSame }
            || texts.contains { $0.value.caseInsensitiveCompare("WhatsApp") == .orderedSame }
        guard isWhatsApp else { return nil }
        let hash = CFHash(root)
        if occurrences.count > 64 { occurrences = occurrences.filter { Date().timeIntervalSince($0.value.date) < 10 } }
        let occurrence: Occurrence
        if let prior = occurrences[hash], Date().timeIntervalSince(prior.date) < 10 { occurrence = prior }
        else { occurrence = .init(key: UUID().uuidString, date: Date()); occurrences[hash] = occurrence }
        return NotificationBannerParser.parse(.init(appName: "WhatsApp", bundleID: bundle ?? "net.whatsapp.WhatsApp",
            texts: texts, sourceKey: occurrence.key, observedAt: occurrence.date))
    }
}
