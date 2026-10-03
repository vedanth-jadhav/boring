import Foundation

struct NotificationQueueState: Equatable, Sendable {
    private(set) var notifications: [MirroredNotification] = []
    private var seen: [String] = []
    static let limit = 32
    mutating func upsert(_ notification: MirroredNotification) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index] = notification
            notifications.sort { $0.receivedAt > $1.receivedAt }
            return
        }
        guard !seen.contains(notification.id) else { return }
        seen.append(notification.id)
        if seen.count > 256 { seen.removeFirst(seen.count - 256) }
        let insertion = notifications.firstIndex { $0.receivedAt <= notification.receivedAt } ?? notifications.endIndex
        notifications.insert(notification, at: insertion)
        if notifications.count > Self.limit { notifications.removeLast(notifications.count - Self.limit) }
    }
    mutating func remove(_ id: String) { notifications.removeAll { $0.id == id } }
    mutating func reset() { notifications.removeAll() }
}
