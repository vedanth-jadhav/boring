import Foundation

/// Only semantic data crosses the capture boundary. No AX control, action name,
/// source availability or native editor state is part of this model.
struct MirroredNotification: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let receivedAt: Date
    var iconData: Data? = nil
    var bundleIdentifier: String? { bundleID }
}
// Compatibility with the existing live-activity enum; the value is now clean.
typealias SystemNotification = MirroredNotification

struct NotificationSourceEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case upsert, ready, unavailable }
    enum Failure: String, Codable, Sendable { case fullDiskAccess, missingStore, unsupportedSchema, disconnected }
    var version = 2
    var kind: Kind
    var notification: MirroredNotification? = nil
    var failure: Failure? = nil
}
