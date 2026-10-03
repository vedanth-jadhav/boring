import Foundation

/// Internal capture snapshot, never sent to the app or exposed to SwiftUI.
struct NotificationBannerText: Sendable {
    let value: String
    let identifier: String
    let x: Double
    let y: Double
}
struct NotificationBannerSnapshot: Sendable {
    let appName: String
    let bundleID: String
    let texts: [NotificationBannerText]
    let sourceKey: String
    let observedAt: Date
}
enum NotificationBannerParser {
    static func parse(_ snapshot: NotificationBannerSnapshot) -> MirroredNotification? {
        let app = snapshot.appName.lowercased()
        let texts = snapshot.texts.filter {
            guard let value = NotificationParser.clean($0.value) else { return false }
            let identifier = $0.identifier.lowercased()
            return value.lowercased() != app && !identifier.contains("time") && !identifier.contains("date")
                && !["now", "notification center"].contains(value.lowercased())
        }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        guard !texts.isEmpty else { return nil }
        let titles = texts.filter { $0.identifier.lowercased().contains("title") && !$0.identifier.lowercased().contains("subtitle") }
        guard titles.count <= 1 else { return nil }
        if titles.isEmpty, Set(texts.map(\.y)).count < 2 { return nil }
        let titleNode = texts.first { $0.identifier.lowercased().contains("title") && !$0.identifier.lowercased().contains("subtitle") } ?? texts.first!
        let title = NotificationParser.clean(titleNode.value)
        let subtitleNode = texts.first { $0.identifier.lowercased().contains("subtitle") }
        let bodyNodes = texts.filter {
            ($0.identifier != titleNode.identifier || $0.x != titleNode.x || $0.y != titleNode.y)
                && !$0.identifier.lowercased().contains("subtitle")
        }
        let body = NotificationParser.clean(bodyNodes.map(\.value).joined(separator: "\n"))
        // Wait for the complete banner instead of publishing an empty shell.
        guard let title, let body else { return nil }
        let id = NotificationParser.fingerprint(fields: [snapshot.bundleID.lowercased(), title, body, snapshot.sourceKey])
        return .init(id: "banner:" + id, appName: snapshot.appName, bundleID: snapshot.bundleID,
                     title: title, subtitle: subtitleNode?.value, body: body, receivedAt: snapshot.observedAt)
    }
}
