import Foundation

enum NativeBannerMatch {
    static func matches(_ item: MirroredNotification, texts: [String], appDescription: String?, bundleID: String?) -> Bool {
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let title = item.title, let body = item.body, !title.isEmpty, !body.isEmpty else { return false }
        let values = texts.map(normalized)
        guard values.contains(normalized(title)), values.contains(normalized(body)) else { return false }
        if let bundleID, let expected = item.bundleID { return bundleID.caseInsensitiveCompare(expected) == .orderedSame }
        guard let app = item.appName else { return false }
        if values.contains(where: { $0.caseInsensitiveCompare(normalized(app)) == .orderedSame }) { return true }
        guard let description = appDescription else { return false }
        return NotificationParser.clean(description.components(separatedBy: ",").first)?.caseInsensitiveCompare(app) == .orderedSame
    }
    static func isDismissLabel(_ label: String) -> Bool {
        ["close", "dismiss", "close notification", "dismiss notification"].contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func isDismissAction(_ action: String) -> Bool {
        var label = String(action.split(separator: "\n", maxSplits: 1).first ?? "")
        if label.hasPrefix("Name:") { label = String(label.dropFirst(5)) }
        return isDismissLabel(label)
    }
}
